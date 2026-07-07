import XCTest
import MacToolsPluginKit
@testable import KeepAwakePlugin

@MainActor
final class KeepAwakePluginTests: XCTestCase {
    func testPermanentSessionPersistsAndRestoresAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertEqual(firstFactory.sessions[0].startedEndDates.count, 1)
        XCTAssertNil(firstFactory.sessions[0].startedEndDates[0])

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertTrue(secondPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(secondFactory.sessions.count, 1)
        XCTAssertEqual(secondFactory.sessions[0].startedEndDates.count, 1)
        XCTAssertNil(secondFactory.sessions[0].startedEndDates[0])
    }

    func testTemporarySessionDoesNotRestoreAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        firstPlugin.handleAction(.setSelection(controlID: "duration", optionID: "oneHour"))

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertEqual(firstFactory.sessions[0].startedEndDates.count, 2)
        XCTAssertNotNil(firstFactory.sessions[0].startedEndDates[1])

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    func testManualSwitchOffClearsPermanentRestoreState() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)

        firstPlugin.handleAction(.setSwitch(false))

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    private static func context(storage: KeepAwakeMemoryStorage) -> PluginRuntimeContext {
        PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
    }
}

@MainActor
private final class KeepAwakeSessionFactory {
    private(set) var sessions: [MockKeepAwakeSession] = []

    func makePlugin(storage: KeepAwakeMemoryStorage) -> KeepAwakePlugin {
        KeepAwakePlugin(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage),
            sessionFactory: { [weak self] _, onEnd in
                let session = MockKeepAwakeSession(onEnd: onEnd)
                self?.sessions.append(session)
                return session
            }
        )
    }
}

@MainActor
private final class MockKeepAwakeSession: KeepAwakeSessionManaging {
    private let onEnd: (KeepAwakeSession.EndReason) -> Void
    private(set) var startedEndDates: [Date?] = []
    private(set) var stopRequestCount = 0

    init(onEnd: @escaping (KeepAwakeSession.EndReason) -> Void) {
        self.onEnd = onEnd
    }

    func start(until endDate: Date?) throws {
        startedEndDates.append(endDate)
    }

    func requestStop(reason: KeepAwakeSession.EndReason) {
        stopRequestCount += 1
        onEnd(reason)
    }
}

@MainActor
private final class KeepAwakeMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            values.removeValue(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
