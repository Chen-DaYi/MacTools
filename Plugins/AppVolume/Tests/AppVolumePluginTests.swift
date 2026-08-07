import CoreAudio
import XCTest
import MacToolsPluginKit
@testable import AppVolumePlugin
@testable import MacTools

@MainActor
final class AppVolumePluginTests: XCTestCase {
    func testMetadataAndPermissionRequirement() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "app-volume")
        XCTAssertEqual(plugin.metadata.title, "应用音量")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .disclosure)
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["system-audio-recording"])
    }

    func testPanelShowsSliderForEachPlayingApplication() {
        let monitor = AppVolumeMonitorMock()
        let plugin = makePlugin(monitor: monitor)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))

        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 41),
            application(id: "com.example.browser", name: "Browser", objectID: 42),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))

        let state = plugin.primaryPanelState
        let sliders = state.detail?.controls.filter { $0.kind == .slider } ?? []
        XCTAssertEqual(sliders.map(\.sectionTitle), ["Browser", "Music"])
        XCTAssertEqual(sliders.compactMap(\.sliderValue), [1, 1])
        XCTAssertEqual(sliders.map(\.valueLabel), ["100%", "100%"])
        XCTAssertEqual(state.subtitle, "2 个应用正在播放")
    }

    func testChangingSliderRequestsAccessAndRoutesTarget() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 51),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.primaryPanelState.detail?.controls.first?.id)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.35, phase: .ended))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(router.accessRequestCount, 1)
        let target = try XCTUnwrap(router.lastTargets.first)
        XCTAssertEqual(target.id, "com.example.music")
        XCTAssertEqual(target.gain, 0.35, accuracy: 0.001)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testReturningSliderToUnityStopsProcessing() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 61),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.primaryPanelState.detail?.controls.first?.id)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.5, phase: .ended))
        await Task.yield()
        await Task.yield()
        plugin.handleAction(.setSlider(controlID: sliderID, value: 1, phase: .ended))

        XCTAssertTrue(router.lastTargets.isEmpty)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testVolumePreferenceIsRestoredForMatchingApplication() throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let firstPlugin = makePlugin(storage: storage, monitor: monitor)
        firstPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 71),
        ]))
        firstPlugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(firstPlugin.primaryPanelState.detail?.controls.first?.id)
        firstPlugin.handleAction(.setSlider(controlID: sliderID, value: 0.2, phase: .ended))

        let secondMonitor = AppVolumeMonitorMock()
        let secondPlugin = makePlugin(storage: storage, monitor: secondMonitor)
        secondPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        secondMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 72),
        ]))
        secondPlugin.handleAction(.setDisclosureExpanded(true))

        XCTAssertEqual(secondPlugin.primaryPanelState.detail?.controls.first?.sliderValue, 0.2)
    }

    func testRestoredVolumeDoesNotRequestAccessUntilUserChangesIt() async throws {
        let storage = AppVolumeStorageMock()
        let firstMonitor = AppVolumeMonitorMock()
        let firstPlugin = makePlugin(storage: storage, monitor: firstMonitor)
        firstPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        firstMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 81),
        ]))
        firstPlugin.handleAction(.setDisclosureExpanded(true))
        let firstSliderID = try XCTUnwrap(firstPlugin.primaryPanelState.detail?.controls.first?.id)
        firstPlugin.handleAction(.setSlider(controlID: firstSliderID, value: 0.2, phase: .ended))

        let restoredMonitor = AppVolumeMonitorMock()
        let restoredRouter = AppVolumeRouterMock(accessResult: true)
        let restoredPlugin = makePlugin(storage: storage, monitor: restoredMonitor, router: restoredRouter)
        restoredPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 82),
        ]))
        await Task.yield()

        XCTAssertEqual(restoredRouter.accessRequestCount, 0)
        XCTAssertTrue(restoredRouter.lastTargets.isEmpty)
    }

    func testDeactivationStopsMonitorAndRouter() {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock()
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))

        plugin.deactivate(reason: .disabled)

        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(router.didStop)
        XCTAssertTrue(plugin.primaryPanelState.detail?.controls.isEmpty ?? true)
    }

    func testUnsupportedSystemDisablesPlugin() {
        let router = AppVolumeRouterMock(isSupported: false)
        let plugin = makePlugin(router: router)

        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "需要 macOS 15 或更高版本")
        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testCanonicalActionsPublishMuteAndFullVolumeForEachPlayingApp() {
        let monitor = AppVolumeMonitorMock()
        let plugin = makePlugin(monitor: monitor)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 91),
        ]))

        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), ["Music · 0%", "Music · 100%"])
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .unavailable)
    }

    func testCanonicalMuteRequestsAccessAndRoutesTheTarget() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 92),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(router.accessRequestCount, 1)
        XCTAssertEqual(router.lastTargets.first?.gain, 0)
    }

    func testCanonicalActionBecomesUnavailableWhenTheAppStopsPlaying() throws {
        let monitor = AppVolumeMonitorMock()
        let plugin = makePlugin(monitor: monitor)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 93),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        monitor.send(snapshot(applications: []))

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    private func makePlugin(
        storage: AppVolumeStorageMock? = nil,
        monitor: AppVolumeMonitorMock? = nil,
        router: AppVolumeRouterMock? = nil
    ) -> AppVolumePlugin {
        AppVolumePlugin(
            storage: storage ?? AppVolumeStorageMock(),
            monitor: monitor ?? AppVolumeMonitorMock(),
            router: router ?? AppVolumeRouterMock()
        )
    }

    private func snapshot(applications: [AudioApplication]) -> AudioApplicationSnapshot {
        AudioApplicationSnapshot(
            applications: applications.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            outputDeviceUID: "test-output"
        )
    }

    private func application(id: String, name: String, objectID: AudioObjectID) -> AudioApplication {
        AudioApplication(
            id: id,
            displayName: name,
            bundleIdentifier: id,
            processObjectIDs: [objectID]
        )
    }
}

@MainActor
private final class AppVolumeMonitorMock: AudioApplicationMonitoring {
    var onUpdate: ((AudioApplicationSnapshot) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func refresh() {}

    func stop() {
        isRunning = false
    }

    func send(_ snapshot: AudioApplicationSnapshot) {
        onUpdate?(snapshot)
    }
}

@MainActor
private final class AppVolumeRouterMock: ApplicationVolumeRouting {
    let isSupported: Bool
    let accessResult: Bool
    private(set) var accessRequestCount = 0
    private(set) var updates: [[ApplicationVolumeTarget]] = []
    private(set) var didStop = false

    var lastTargets: [ApplicationVolumeTarget] {
        updates.last ?? []
    }

    init(isSupported: Bool = true, accessResult: Bool = true) {
        self.isSupported = isSupported
        self.accessResult = accessResult
    }

    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?) {
        updates.append(targets)
    }

    func requestSystemAudioAccess() async -> Bool {
        accessRequestCount += 1
        return accessResult
    }

    func stop() {
        didStop = true
    }
}

@MainActor
private final class AppVolumeStorageMock: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
