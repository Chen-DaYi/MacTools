import Foundation
import MacToolsPluginKit
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsTestStorage: PluginStorage {
    var values: [String: Any] = [:]
    var blocksWrites = false

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blocksWrites else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values[key] = nil }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values[legacyKey] = nil
    }
}

struct AppleShortcutsVisualMetadataStub: AppleShortcutsVisualMetadataLoading {
    let result: Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError>
    let iconResult: Result<Data?, AppleShortcutsVisualMetadataError>

    init(
        result: Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> = .success([:]),
        iconResult: Result<Data?, AppleShortcutsVisualMetadataError> = .success(nil)
    ) {
        self.result = result
        self.iconResult = iconResult
    }

    func loadVisualMetadata() async -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        result
    }

    func loadIcon(for _: UUID) async -> Result<Data?, AppleShortcutsVisualMetadataError> {
        iconResult
    }
}

actor AppleShortcutsVisualMetadataCountingStub: AppleShortcutsVisualMetadataLoading {
    private let result: Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError>
    private let iconResult: Result<Data?, AppleShortcutsVisualMetadataError>
    private var callCount = 0
    private var iconCallCount = 0

    init(
        result: Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError>,
        iconResult: Result<Data?, AppleShortcutsVisualMetadataError> = .success(nil)
    ) {
        self.result = result
        self.iconResult = iconResult
    }

    func loadVisualMetadata() async -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        callCount += 1
        return result
    }

    func loadIcon(for _: UUID) async -> Result<Data?, AppleShortcutsVisualMetadataError> {
        iconCallCount += 1
        return iconResult
    }

    func observedCallCount() -> Int { callCount }
    func observedIconCallCount() -> Int { iconCallCount }
}

actor AppleShortcutsVisualMetadataDelayedStub: AppleShortcutsVisualMetadataLoading {
    private let result: Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError>
    private let delay: Duration
    private var callCount = 0

    init(
        result: Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError>,
        delay: Duration
    ) {
        self.result = result
        self.delay = delay
    }

    func loadVisualMetadata() async -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        callCount += 1
        try? await Task.sleep(for: delay)
        return result
    }

    func loadIcon(for _: UUID) async -> Result<Data?, AppleShortcutsVisualMetadataError> {
        .success(nil)
    }

    func observedCallCount() -> Int { callCount }
}

actor AppleShortcutsRunnerStub: AppleShortcutsCommandRunning {
    nonisolated let isExecutableAvailable: Bool
    private var shortcuts: [AppleShortcutItem]
    private var folders: [AppleShortcutFolder]
    private var memberships: [UUID: Result<[AppleShortcutItem], StubFailure>]
    private let runResult: Result<AppleShortcutsCommandResult, StubFailure>
    private let delay: Duration?
    private let membershipDelay: Duration?
    private let ignoresCancellation: Bool
    private var listFails: Bool
    private var activeMembershipCallCount = 0
    private var maximumConcurrentMembershipCallCount = 0
    private var membershipCallIDs: [UUID] = []
    private(set) var listCallCount = 0
    private(set) var folderListCallCount = 0
    private(set) var runIDs: [UUID] = []
    private(set) var viewNames: [String] = []

    enum StubFailure: Error { case failed }

    init(
        isExecutableAvailable: Bool = true,
        shortcuts: [AppleShortcutItem] = [],
        folders: [AppleShortcutFolder] = [],
        memberships: [UUID: Result<[AppleShortcutItem], StubFailure>] = [:],
        runResult: Result<AppleShortcutsCommandResult, StubFailure> = .success(
            AppleShortcutsCommandResult(
                exitCode: 0,
                standardOutput: "",
                standardError: "",
                outputWasTruncated: false
            )
        ),
        delay: Duration? = nil,
        membershipDelay: Duration? = nil,
        listFails: Bool = false,
        ignoresCancellation: Bool = false
    ) {
        self.isExecutableAvailable = isExecutableAvailable
        self.shortcuts = shortcuts
        self.folders = folders
        self.memberships = memberships
        self.runResult = runResult
        self.delay = delay
        self.membershipDelay = membershipDelay
        self.listFails = listFails
        self.ignoresCancellation = ignoresCancellation
    }

    func listShortcuts() async throws -> [AppleShortcutItem] {
        listCallCount += 1
        let result = shortcuts
        if let delay {
            if ignoresCancellation { try? await Task.sleep(for: delay) }
            else { try await Task.sleep(for: delay) }
        }
        if listFails { throw StubFailure.failed }
        return result
    }

    func listFolders() async throws -> [AppleShortcutFolder] {
        folderListCallCount += 1
        return folders
    }

    func listShortcuts(inFolder id: UUID) async throws -> [AppleShortcutItem] {
        membershipCallIDs.append(id)
        activeMembershipCallCount += 1
        maximumConcurrentMembershipCallCount = max(
            maximumConcurrentMembershipCallCount,
            activeMembershipCallCount
        )
        defer { activeMembershipCallCount -= 1 }
        let result = memberships[id, default: .success([])]
        if let membershipDelay {
            try await Task.sleep(for: membershipDelay)
        }
        return try result.get()
    }

    func runShortcut(id: UUID) async throws -> AppleShortcutsCommandResult {
        runIDs.append(id)
        if let delay {
            if ignoresCancellation { try? await Task.sleep(for: delay) }
            else { try await Task.sleep(for: delay) }
        }
        return try runResult.get()
    }

    func viewShortcut(name: String) async throws {
        viewNames.append(name)
        if let delay {
            if ignoresCancellation { try? await Task.sleep(for: delay) }
            else { try await Task.sleep(for: delay) }
        }
    }

    func setShortcuts(_ value: [AppleShortcutItem]) { shortcuts = value }
    func setMemberships(_ value: [UUID: Result<[AppleShortcutItem], StubFailure>]) {
        memberships = value
    }
    func setListFails(_ value: Bool) { listFails = value }
    func observedListCallCount() -> Int { listCallCount }
    func observedFolderListCallCount() -> Int { folderListCallCount }
    func observedRunIDs() -> [UUID] { runIDs }
    func observedViewNames() -> [String] { viewNames }
    func observedMembershipCallIDs() -> [UUID] { membershipCallIDs }
    func observedMaximumConcurrentMembershipCallCount() -> Int {
        maximumConcurrentMembershipCallCount
    }
}

actor NonzeroAppleShortcutsRunnerStub: AppleShortcutsCommandRunning {
    nonisolated let isExecutableAvailable = true
    let item: AppleShortcutItem
    let result: AppleShortcutsCommandResult

    init(item: AppleShortcutItem, result: AppleShortcutsCommandResult) {
        self.item = item
        self.result = result
    }

    func listShortcuts() async throws -> [AppleShortcutItem] { [item] }
    func listFolders() async throws -> [AppleShortcutFolder] { [] }
    func listShortcuts(inFolder _: UUID) async throws -> [AppleShortcutItem] { [] }
    func runShortcut(id _: UUID) async throws -> AppleShortcutsCommandResult {
        throw AppleShortcutsCommandError.nonzeroExit(result)
    }
    func viewShortcut(name _: String) async throws {}
}
