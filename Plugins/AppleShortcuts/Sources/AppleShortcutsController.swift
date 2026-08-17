import Combine
import Foundation
import MacToolsPluginKit

struct AppleShortcutsSnapshot: Equatable, Sendable {
    var discovery: AppleShortcutsDiscovery = .empty
    var isRefreshing = false
    var lastSuccessfulRefresh: Date?
    var errorMessage: String?
    var operationMessage: String?

    var shortcutIDs: Set<UUID> { Set(discovery.shortcuts.map(\.id)) }
}

enum AppleShortcutsExecutionStartError: Error, Equatable, Sendable {
    case cancelled
    case inactive
    case alreadyRunning
    case concurrencyLimit
}

@MainActor
final class AppleShortcutsController: ObservableObject {
    struct ActiveRun {
        let token: UUID
        let task: Task<ActionExecutionResult, Never>
    }

    private struct ActiveView {
        let token: UUID
        let task: Task<Void, Never>
    }

    static let freshnessInterval: TimeInterval = 60
    static let maximumConcurrentRuns = 4
    static let maximumConcurrentMembershipQueries = 4

    @Published private(set) var snapshot = AppleShortcutsSnapshot()

    let executionStore: AppleShortcutsExecutionStore
    var onStateChange: (() -> Void)?

    private let runner: any AppleShortcutsCommandRunning
    private let visualMetadataLoader: any AppleShortcutsVisualMetadataLoading
    private let localization: PluginLocalization
    private let now: () -> Date
    private let automaticRefreshInterval: Duration
    private var refreshTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var refreshToken: UUID?
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var activeViews: [UUID: ActiveView] = [:]
    private var isActive = true
    private var isAutomaticRefreshEnabled = false
    private var visualMetadataIsUnavailable = false
    private var lifecycleGeneration = 0

    init(
        executionStore: AppleShortcutsExecutionStore = AppleShortcutsExecutionStore(),
        runner: any AppleShortcutsCommandRunning,
        visualMetadataLoader: any AppleShortcutsVisualMetadataLoading = AppleShortcutsVisualMetadataLoader(),
        localization: PluginLocalization,
        now: @escaping () -> Date = { .now },
        automaticRefreshInterval: Duration = .seconds(60)
    ) {
        self.executionStore = executionStore
        self.runner = runner
        self.visualMetadataLoader = visualMetadataLoader
        self.localization = localization
        self.now = now
        self.automaticRefreshInterval = automaticRefreshInterval
    }

    var isExecutableAvailable: Bool {
        runner.isExecutableAvailable
    }

    func activate() {
        lifecycleGeneration += 1
        isActive = true
        isAutomaticRefreshEnabled = true
        updateAutomaticRefreshScheduling()
        refreshIfNeeded()
    }

    func refreshIfNeeded() {
        guard let refreshed = snapshot.lastSuccessfulRefresh,
              now().timeIntervalSince(refreshed) < Self.freshnessInterval else {
            refresh(force: false)
            return
        }
    }

    func refresh(force: Bool = true) {
        guard refreshTask == nil else { return }
        if !force,
           let refreshed = snapshot.lastSuccessfulRefresh,
           now().timeIntervalSince(refreshed) < Self.freshnessInterval { return }
        let token = UUID()
        let generation = lifecycleGeneration
        refreshToken = token
        refreshTask = Task { @MainActor [weak self] in
            await self?.performRefresh(
                expectedGeneration: generation,
                token: token,
                refreshVisualMetadata: force || !(self?.visualMetadataIsUnavailable ?? true)
            )
            guard self?.refreshToken == token else { return }
            self?.refreshTask = nil
            self?.refreshToken = nil
        }
    }

    func performRefresh(
        expectedGeneration: Int? = nil,
        token: UUID? = nil,
        refreshVisualMetadata: Bool = true
    ) async {
        let generation = expectedGeneration ?? lifecycleGeneration
        guard isActive else { return }
        snapshot.isRefreshing = true
        snapshot.errorMessage = nil
        snapshot.operationMessage = nil
        defer {
            if token == nil || refreshToken == token {
                snapshot.isRefreshing = false
            }
        }

        do {
            async let shortcutsRequest = runner.listShortcuts()
            async let foldersRequest = runner.listFolders()
            async let visualMetadataRequest = refreshVisualMetadata
                ? visualMetadataLoader.loadVisualMetadata()
                : .success([UUID: AppleShortcutVisualMetadata]())
            let (shortcuts, folders, visualMetadataResult) = try await (
                shortcutsRequest,
                foldersRequest,
                visualMetadataRequest
            )
            try Task.checkCancellation()
            var memberships = try await loadMemberships(for: folders)
            try Task.checkCancellation()
            guard isActive, lifecycleGeneration == generation else { return }

            for folderID in memberships.failedFolderIDs {
                memberships.memberships[folderID] = snapshot.discovery.folderMemberships[folderID] ?? []
            }

            let previousVisualMetadata = Dictionary(
                uniqueKeysWithValues: snapshot.discovery.shortcuts.compactMap { item in
                    item.visualMetadata.map { (item.id, $0) }
                }
            )
            let visualMetadata: [UUID: AppleShortcutVisualMetadata]
            switch visualMetadataResult {
            case let .success(metadata):
                visualMetadataIsUnavailable = false
                visualMetadata = metadata
            case .failure:
                visualMetadataIsUnavailable = true
                visualMetadata = [:]
            }
            var itemsByID = Dictionary(uniqueKeysWithValues: shortcuts.map { item in
                (item.id, AppleShortcutItem(
                    id: item.id,
                    name: item.name,
                    visualMetadata: visualMetadata[item.id] ?? previousVisualMetadata[item.id]
                ))
            })
            for (folderID, memberIDs) in memberships.memberships {
                for memberID in memberIDs {
                    itemsByID[memberID]?.folderIDs.insert(folderID)
                }
            }
            let discovery = AppleShortcutsDiscovery(
                shortcuts: itemsByID.values.sorted(by: Self.shortcutOrder),
                folders: folders.sorted(by: Self.folderOrder),
                folderMemberships: memberships.memberships,
                failedFolderIDs: memberships.failedFolderIDs
            )

            snapshot.discovery = discovery
            snapshot.lastSuccessfulRefresh = now()
            snapshot.errorMessage = memberships.failedFolderIDs.isEmpty ? nil : localization.string(
                "refresh.folder.partial",
                defaultValue: "部分文件夹无法刷新；已保留上次的成员。"
            )
            onStateChange?()
        } catch is CancellationError {
            return
        } catch {
            guard isActive, lifecycleGeneration == generation else { return }
            snapshot.errorMessage = message(for: error, fallback: localization.string(
                "refresh.failed",
                defaultValue: "无法刷新快捷指令；已保留上次结果。"
            ))
        }
    }

    func startExecution(
        shortcutID: UUID,
        name: String
    ) -> Result<ActiveRun, AppleShortcutsExecutionStartError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard isActive else { return .failure(.inactive) }
        guard activeRuns[shortcutID] == nil else { return .failure(.alreadyRunning) }
        guard activeRuns.count < Self.maximumConcurrentRuns else {
            return .failure(.concurrencyLimit)
        }
        let token = UUID()
        let generation = lifecycleGeneration
        let task: Task<ActionExecutionResult, Never> = Task { @MainActor [weak self] in
            guard let self else { return ActionExecutionResult.cancelled }
            return await self.execute(
                shortcutID: shortcutID,
                name: name,
                expectedGeneration: generation
            )
        }
        let run = ActiveRun(token: token, task: task)
        activeRuns[shortcutID] = run
        onStateChange?()
        return .success(run)
    }

    func presentExecutionStartError(_ error: AppleShortcutsExecutionStartError) {
        snapshot.operationMessage = nil
        snapshot.errorMessage = executionStartMessage(for: error)
    }

    func waitForExecution(_ run: ActiveRun, shortcutID: UUID) async -> ActionExecutionResult {
        let result = await run.task.value
        if activeRuns[shortcutID]?.token == run.token {
            activeRuns.removeValue(forKey: shortcutID)
            onStateChange?()
        }
        return result
    }

    func cancelExecution(shortcutID: UUID) {
        activeRuns[shortcutID]?.task.cancel()
    }

    func isRunning(_ shortcutID: UUID) -> Bool { activeRuns[shortcutID] != nil }

    func executionStartMessage(for error: AppleShortcutsExecutionStartError) -> String {
        switch error {
        case .cancelled:
            localization.string("run.cancelled", defaultValue: "运行已取消。")
        case .inactive:
            localization.string(
                "run.unavailable.inactive",
                defaultValue: "Apple 快捷指令插件当前未启用。"
            )
        case .alreadyRunning:
            localization.string(
                "action.unavailable.running",
                defaultValue: "此快捷指令正在运行。"
            )
        case .concurrencyLimit:
            localization.string(
                "run.unavailable.limit",
                defaultValue: "同时最多运行 4 个快捷指令。"
            )
        }
    }

    func openInShortcuts(_ shortcutID: UUID) {
        guard isActive else { return }
        guard let shortcut = snapshot.discovery.shortcuts.first(where: { $0.id == shortcutID }) else {
            snapshot.operationMessage = nil
            snapshot.errorMessage = localization.string(
                "view.missing",
                defaultValue: "在 Apple“快捷指令”中找不到此项目。"
            )
            return
        }
        let sameNameCount = snapshot.discovery.shortcuts.lazy.filter {
            $0.name.localizedCaseInsensitiveCompare(shortcut.name) == .orderedSame
        }.count
        guard sameNameCount == 1 else {
            snapshot.operationMessage = nil
            snapshot.errorMessage = localization.string(
                "view.ambiguous",
                defaultValue: "存在同名快捷指令；请直接在 Apple“快捷指令”中打开。"
            )
            return
        }
        activeViews[shortcutID]?.task.cancel()
        let token = UUID()
        let generation = lifecycleGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performOpen(
                shortcutID: shortcutID,
                name: shortcut.name,
                expectedGeneration: generation,
                token: token
            )
        }
        activeViews[shortcutID] = ActiveView(token: token, task: task)
    }

    func presentStoreError(_ error: AppleShortcutsStoreError) {
        snapshot.errorMessage = storeMessage(for: error)
    }

    func deactivate() {
        lifecycleGeneration += 1
        isActive = false
        isAutomaticRefreshEnabled = false
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        snapshot.isRefreshing = false
        snapshot.errorMessage = nil
        snapshot.operationMessage = nil
        let runs = activeRuns.values
        activeRuns.removeAll()
        runs.forEach { $0.task.cancel() }
        let views = activeViews.values
        activeViews.removeAll()
        views.forEach { $0.task.cancel() }
        executionStore.clear()
        onStateChange?()
    }

    private func updateAutomaticRefreshScheduling() {
        guard isAutomaticRefreshEnabled, isActive else {
            automaticRefreshTask?.cancel()
            automaticRefreshTask = nil
            return
        }
        guard automaticRefreshTask == nil else { return }

        let interval = automaticRefreshInterval
        automaticRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, self.isActive else { return }
                self.refresh(force: true)
            }
        }
    }

    private func execute(
        shortcutID: UUID,
        name: String,
        expectedGeneration: Int
    ) async -> ActionExecutionResult {
        guard isCurrent(expectedGeneration) else { return .cancelled }
        let runID = executionStore.begin(shortcutID: shortcutID, name: name)
        do {
            let result = try await runner.runShortcut(id: shortcutID)
            try Task.checkCancellation()
            guard isCurrent(expectedGeneration) else { return .cancelled }
            guard result.exitCode == 0 else {
                let message = result.standardError
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .appleShortcutsNilIfEmpty
                    ?? localization.format(
                        "run.exit.format",
                        defaultValue: "快捷指令退出，状态码 %d。",
                        result.exitCode
                    )
                executionStore.finish(
                    shortcutID: shortcutID,
                    runID: runID,
                    status: .failed,
                    result: result,
                    message: message
                )
                return .failed(message: message)
            }
            let output = result.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .appleShortcutsNilIfEmpty
            executionStore.finish(
                shortcutID: shortcutID,
                runID: runID,
                status: .succeeded,
                result: result,
                message: output
            )
            return .succeeded(message: output)
        } catch is CancellationError {
            if isCurrent(expectedGeneration) {
                executionStore.finish(shortcutID: shortcutID, runID: runID, status: .cancelled)
            }
            return .cancelled
        } catch let AppleShortcutsCommandError.nonzeroExit(result) {
            guard isCurrent(expectedGeneration) else { return .cancelled }
            let message = result.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .appleShortcutsNilIfEmpty
                ?? result.standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .appleShortcutsNilIfEmpty
                ?? localization.format(
                    "run.exit.format",
                    defaultValue: "快捷指令退出，状态码 %d。",
                    result.exitCode
                )
            executionStore.finish(
                shortcutID: shortcutID,
                runID: runID,
                status: .failed,
                result: result,
                message: message
            )
            return .failed(message: message)
        } catch {
            guard isCurrent(expectedGeneration) else { return .cancelled }
            let message = message(for: error, fallback: localization.string(
                "run.failed",
                defaultValue: "快捷指令运行失败。"
            ))
            executionStore.finish(
                shortcutID: shortcutID,
                runID: runID,
                status: .failed,
                message: message
            )
            return .failed(message: message)
        }
    }

    private func performOpen(
        shortcutID: UUID,
        name: String,
        expectedGeneration: Int,
        token: UUID
    ) async {
        defer {
            if activeViews[shortcutID]?.token == token {
                activeViews.removeValue(forKey: shortcutID)
            }
        }
        do {
            try await runner.viewShortcut(name: name)
            try Task.checkCancellation()
            guard isCurrent(expectedGeneration) else { return }
            snapshot.errorMessage = nil
            snapshot.operationMessage = localization.string(
                "view.opened",
                defaultValue: "已在“快捷指令”中打开。"
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(expectedGeneration) else { return }
            snapshot.operationMessage = nil
            snapshot.errorMessage = message(for: error, fallback: localization.string(
                "view.failed",
                defaultValue: "无法在“快捷指令”中打开。"
            ))
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        isActive && lifecycleGeneration == generation
    }

    private struct MembershipResult: Sendable {
        var memberships: [UUID: Set<UUID>]
        var failedFolderIDs: Set<UUID>
    }

    private func loadMemberships(for folders: [AppleShortcutFolder]) async throws -> MembershipResult {
        let runner = runner
        var iterator = folders.makeIterator()
        return try await withThrowingTaskGroup(
            of: (UUID, Result<[AppleShortcutItem], AppleShortcutsMembershipFailure>).self
        ) { group in
            func addNext() {
                guard !Task.isCancelled, let folder = iterator.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        return (folder.id, .success(try await runner.listShortcuts(inFolder: folder.id)))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (folder.id, .failure(.failed))
                    }
                }
            }
            for _ in 0 ..< min(Self.maximumConcurrentMembershipQueries, folders.count) { addNext() }

            var result = MembershipResult(memberships: [:], failedFolderIDs: [])
            do {
                for try await (folderID, membership) in group {
                    try Task.checkCancellation()
                    switch membership {
                    case let .success(shortcuts):
                        result.memberships[folderID] = Set(shortcuts.map(\.id))
                    case .failure:
                        result.failedFolderIDs.insert(folderID)
                    }
                    addNext()
                }
                try Task.checkCancellation()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private enum AppleShortcutsMembershipFailure: Error, Sendable { case failed }

    private func message(for error: Error, fallback: String) -> String {
        switch error {
        case AppleShortcutsCommandError.executableUnavailable:
            return localization.string("error.executable", defaultValue: "系统未提供“快捷指令”命令。")
        case AppleShortcutsCommandError.timedOut:
            return localization.string("error.timeout", defaultValue: "操作超时。")
        case AppleShortcutsCommandError.malformedOutput:
            return localization.string("error.output", defaultValue: "无法读取“快捷指令”返回的数据。")
        case AppleShortcutsCommandError.launchFailed:
            return localization.string(
                "error.launch",
                defaultValue: "无法启动系统“快捷指令”命令。"
            )
        case let AppleShortcutsCommandError.nonzeroExit(result):
            return result.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .appleShortcutsNilIfEmpty
                ?? fallback
        default:
            return fallback
        }
    }

    private func storeMessage(for error: AppleShortcutsStoreError) -> String {
        switch error {
        case .recoveryRequired:
            localization.string(
                "settings.recovery",
                defaultValue: "设置数据需要恢复后才能修改。"
            )
        case .payloadTooLarge, .invalidData, .persistenceFailed:
            localization.string(
                "settings.save.failed",
                defaultValue: "无法保存快捷指令设置。"
            )
        }
    }

    private static func shortcutOrder(_ lhs: AppleShortcutItem, _ rhs: AppleShortcutItem) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }

    private static func folderOrder(_ lhs: AppleShortcutFolder, _ rhs: AppleShortcutFolder) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }
}
