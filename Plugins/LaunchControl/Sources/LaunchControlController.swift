import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class LaunchControlController: ObservableObject {
    @Published private(set) var snapshot = LaunchControlSnapshot()

    var onStateChange: (() -> Void)?

    private let scanner: LaunchControlScanner
    private let runner: any LaunchControlCommandRunning
    private let favoritesStore: LaunchControlFavoritesStore
    private let notesStore: LaunchControlNotesStore
    private let localization: PluginLocalization
    private var refreshTask: Task<Void, Never>?

    init(
        scanner: LaunchControlScanner? = nil,
        runner: any LaunchControlCommandRunning = ProcessLaunchControlCommandRunner(),
        favoritesStore: LaunchControlFavoritesStore? = nil,
        notesStore: LaunchControlNotesStore? = nil,
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "launch-control"),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.runner = runner
        self.favoritesStore = favoritesStore ?? LaunchControlFavoritesStore(context: context)
        self.notesStore = notesStore ?? LaunchControlNotesStore(context: context)
        self.localization = localization
        self.scanner = scanner ?? LaunchControlScanner(runner: runner, localization: localization)
    }

    deinit {
        refreshTask?.cancel()
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil

        guard snapshot.isRefreshing else {
            return
        }

        snapshot.isRefreshing = false
        snapshot.currentScanTarget = nil
        appendScanLog(localization.string("controller.scanLog.stopped", defaultValue: "扫描已停止"))
        onStateChange?()
    }

    func refresh() {
        guard !snapshot.isRefreshing else { return }

        snapshot.isRefreshing = true
        snapshot.items = []
        snapshot.selectedItemID = nil
        snapshot.errorMessage = nil
        snapshot.operationMessage = nil
        snapshot.scanLogEntries = [
            localization.string("controller.scanLog.started", defaultValue: "开始扫描 LaunchAgent / LaunchDaemon")
        ]
        snapshot.currentScanTarget = nil
        onStateChange?()

        let progressStream = AsyncStream<LaunchControlScanEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(120)
        )
        let progressTask = Task { @MainActor [weak self] in
            for await event in progressStream.stream {
                self?.handleScanEvent(event)
            }
        }

        refreshTask = Task { [weak self, scanner, progressStream] in
            let result = await Task.detached(priority: .userInitiated) {
                scanner.scan { event in
                    progressStream.continuation.yield(event)
                }
            }.value
            progressStream.continuation.finish()
            await progressTask.value

            guard let self, !Task.isCancelled else { return }
            self.apply(result: result)
        }
    }

    func selectItem(id: String?) {
        snapshot.selectedItemID = id
        onStateChange?()
    }

    func openInFinder(_ item: LaunchControlItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
    }

    func setFavorite(_ isFavorite: Bool, for item: LaunchControlItem) {
        favoritesStore.setFavorite(isFavorite, for: item.id)
        refreshPersistedState(for: item)
        snapshot.operationMessage = isFavorite
            ? localization.format("controller.favorite.added", defaultValue: "已关注 %@", item.label)
            : localization.format("controller.favorite.removed", defaultValue: "已取消关注 %@", item.label)
        onStateChange?()
    }

    func setNote(_ note: String, for item: LaunchControlItem) {
        notesStore.setNote(note, for: item.id)
        refreshPersistedState(for: item)
        let isCleared = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        snapshot.operationMessage = isCleared
            ? localization.format("controller.note.cleared", defaultValue: "已清除备注：%@", item.label)
            : localization.format("controller.note.saved", defaultValue: "已保存备注：%@", item.label)
        onStateChange?()
    }

    func bootstrap(_ item: LaunchControlItem) {
        performManagedAction(
            item: item,
            title: actionTitle(.bootstrap),
            arguments: ["bootstrap", item.launchctlDomain, item.plistURL.path]
        )
    }

    func bootout(_ item: LaunchControlItem) {
        performManagedAction(
            item: item,
            title: actionTitle(.bootout),
            arguments: ["bootout", item.launchctlDomain, item.plistURL.path]
        )
    }

    func enable(_ item: LaunchControlItem) {
        performManagedAction(
            item: item,
            title: actionTitle(.enable),
            arguments: ["enable", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func disable(_ item: LaunchControlItem) {
        performManagedAction(
            item: item,
            title: actionTitle(.disable),
            arguments: ["disable", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func start(_ item: LaunchControlItem) {
        performManagedAction(
            item: item,
            title: actionTitle(.start),
            arguments: ["kickstart", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func stop(_ item: LaunchControlItem) {
        performManagedAction(
            item: item,
            title: actionTitle(.stop),
            arguments: ["kill", "TERM", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func restart(_ item: LaunchControlItem) {
        performManagedAction(
            item: item,
            title: actionTitle(.restart),
            arguments: ["kickstart", "-k", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    private func apply(result: LaunchControlScanResult) {
        let selectedID = snapshot.selectedItemID
        snapshot.items = sortedItems(result.items.map(applyingPersistedState))
        snapshot.selectedItemID = result.items.contains(where: { $0.id == selectedID })
            ? selectedID
            : result.items.first?.id
        snapshot.isRefreshing = false
        snapshot.lastRefreshDate = Date()
        snapshot.errorMessage = result.warnings.first
        snapshot.currentScanTarget = nil
        appendScanLog(localization.format("controller.scanLog.completed", defaultValue: "扫描完成：%d 项", result.items.count))
        onStateChange?()
    }

    private func handleScanEvent(_ event: LaunchControlScanEvent) {
        switch event {
        case let .directory(path):
            snapshot.currentScanTarget = path
            appendScanLog(localization.format("controller.scanLog.directory", defaultValue: "目录：%@", path))
        case let .file(path):
            snapshot.currentScanTarget = path
            appendScanLog(localization.format(
                "controller.scanLog.file",
                defaultValue: "读取：%@",
                URL(fileURLWithPath: path).lastPathComponent
            ))
        case let .found(item):
            upsertScannedItem(item)
        case let .message(message):
            appendScanLog(message)
        }

        onStateChange?()
    }

    private func upsertScannedItem(_ item: LaunchControlItem) {
        let item = applyingPersistedState(item)

        if let index = snapshot.items.firstIndex(where: { $0.id == item.id }) {
            snapshot.items[index] = item
        } else {
            snapshot.items.append(item)
        }
        snapshot.items = sortedItems(snapshot.items)
        if snapshot.selectedItemID == nil {
            snapshot.selectedItemID = snapshot.items.first?.id
        }
    }

    private func refreshPersistedState(for item: LaunchControlItem) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        snapshot.items[index] = applyingPersistedState(snapshot.items[index])
        snapshot.items = sortedItems(snapshot.items)
    }

    private func applyingPersistedState(_ item: LaunchControlItem) -> LaunchControlItem {
        var updated = item
        updated.isFavorite = favoritesStore.isFavorite(item.id)
        updated.note = notesStore.note(for: item.id)
        return updated
    }

    private func sortedItems(_ items: [LaunchControlItem]) -> [LaunchControlItem] {
        items.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite
            }
            if lhs.origin != rhs.origin {
                return lhs.origin.rawValue < rhs.origin.rawValue
            }
            if lhs.scope != rhs.scope {
                return lhs.scope.rawValue < rhs.scope.rawValue
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private func appendScanLog(_ message: String) {
        snapshot.scanLogEntries.append(message)
        if snapshot.scanLogEntries.count > 80 {
            snapshot.scanLogEntries.removeFirst(snapshot.scanLogEntries.count - 80)
        }
    }

    private func performManagedAction(
        item: LaunchControlItem,
        title: String,
        arguments: [String]
    ) {
        guard item.canManage else {
            snapshot.operationMessage = localization.string(
                "controller.operation.readOnly",
                defaultValue: "系统或全局启动项默认只读，避免误操作。"
            )
            onStateChange?()
            return
        }

        snapshot.operationMessage = localization.format(
            "controller.operation.running",
            defaultValue: "%@ %@...",
            title,
            item.label
        )
        snapshot.errorMessage = nil
        onStateChange?()

        Task { [weak self, runner] in
            let result: Result<LaunchControlCommandResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try runner.runLaunchctl(arguments: arguments))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }

            switch result {
            case let .success(commandResult) where commandResult.exitCode == 0:
                self.snapshot.operationMessage = self.localization.format(
                    "controller.operation.completed",
                    defaultValue: "%@完成",
                    title
                )
                self.refresh()
            case let .success(commandResult):
                let message = commandResult.combinedOutput
                self.snapshot.operationMessage = self.localization.format(
                    "controller.operation.failed",
                    defaultValue: "%@失败",
                    title
                )
                self.snapshot.errorMessage = message.isEmpty
                    ? self.localization.format(
                        "controller.operation.exitCode",
                        defaultValue: "launchctl 返回退出码 %d",
                        commandResult.exitCode
                    )
                    : message
                self.onStateChange?()
            case let .failure(error):
                self.snapshot.operationMessage = self.localization.format(
                    "controller.operation.failed",
                    defaultValue: "%@失败",
                    title
                )
                self.snapshot.errorMessage = error.localizedDescription
                self.onStateChange?()
            }
        }
    }

    private func actionTitle(_ action: LaunchControlManagedAction) -> String {
        action.title(localization: localization)
    }
}
