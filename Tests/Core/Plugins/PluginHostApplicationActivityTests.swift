import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostApplicationActivityTests: XCTestCase {
    func testHostDeliversInitialAndSubsequentActivityStates() {
        let observer = StubApplicationActivityObserver(state: .displayAsleep)
        let plugin = RecordingApplicationActivityPlugin()
        let suiteName = "PluginHostApplicationActivityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            applicationActivityObserver: observer
        )

        XCTAssertEqual(plugin.states, [.displayAsleep])
        observer.send(.interactive)
        XCTAssertEqual(plugin.states, [.displayAsleep, .interactive])
        withExtendedLifetime(host) {}
    }
}

@MainActor
private final class StubApplicationActivityObserver: ApplicationActivityObserving {
    private(set) var state: PluginApplicationActivityState
    var onStateChange: ((PluginApplicationActivityState) -> Void)?

    init(state: PluginApplicationActivityState) {
        self.state = state
    }

    func send(_ state: PluginApplicationActivityState) {
        self.state = state
        onStateChange?(state)
    }
}

@MainActor
private final class RecordingApplicationActivityPlugin: MacToolsPlugin,
    PluginApplicationActivityStateHandling {
    let metadata = PluginMetadata(
        id: "activity-recorder",
        title: "Activity Recorder",
        iconName: "bolt",
        iconTint: Color.primary,
        order: 0,
        defaultDescription: ""
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var states: [PluginApplicationActivityState] = []

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        states.append(state)
    }
}
