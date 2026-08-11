import XCTest
import MacToolsPluginKit
@testable import MiddleClickPlugin

@MainActor
private final class MiddleClickMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard legacyKey != key, values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
private final class MockMiddleClickSession: MiddleClickSessionManaging {
    var requiredFingerCount = 3 {
        didSet { assignedFingerCounts.append(requiredFingerCount) }
    }

    private(set) var assignedFingerCounts: [Int] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    func activate() {
        activateCallCount += 1
    }

    func deactivate() {
        deactivateCallCount += 1
    }
}

@MainActor
final class MiddleClickPluginTests: XCTestCase {
    func testThreeFingerTapRecognizesAfterAllContactsRelease() {
        var recognizer = MiddleClickTapRecognizer(fingerCount: 3)

        XCTAssertFalse(recognizer.process(frame(at: 1.00, contacts: [contact(1)])))
        XCTAssertFalse(recognizer.process(frame(
            at: 1.03,
            contacts: [contact(1), contact(2), contact(3)]
        )))
        XCTAssertFalse(recognizer.process(frame(
            at: 1.12,
            contacts: [contact(2), contact(3)]
        )))
        XCTAssertTrue(recognizer.process(frame(at: 1.16, contacts: [])))
    }

    func testTapRejectsMovementAndExcessDuration() {
        var movingRecognizer = MiddleClickTapRecognizer(fingerCount: 3)
        XCTAssertFalse(movingRecognizer.process(frame(
            at: 1.00,
            contacts: [contact(1), contact(2), contact(3)]
        )))
        XCTAssertFalse(movingRecognizer.process(frame(
            at: 1.08,
            contacts: [contact(1, x: 0.20), contact(2), contact(3)]
        )))
        XCTAssertFalse(movingRecognizer.process(frame(at: 1.10, contacts: [])))

        var slowRecognizer = MiddleClickTapRecognizer(fingerCount: 3)
        XCTAssertFalse(slowRecognizer.process(frame(
            at: 2.00,
            contacts: [contact(1), contact(2), contact(3)]
        )))
        XCTAssertFalse(slowRecognizer.process(frame(at: 2.31, contacts: [])))
    }

    func testTapRejectsTooManyOrSequentialFingers() {
        var tooManyRecognizer = MiddleClickTapRecognizer(fingerCount: 3)
        XCTAssertFalse(tooManyRecognizer.process(frame(
            at: 1.00,
            contacts: [contact(1), contact(2), contact(3), contact(4)]
        )))
        XCTAssertFalse(tooManyRecognizer.process(frame(at: 1.10, contacts: [])))

        var sequentialRecognizer = MiddleClickTapRecognizer(fingerCount: 3)
        XCTAssertFalse(sequentialRecognizer.process(frame(at: 2.00, contacts: [contact(1)])))
        XCTAssertFalse(sequentialRecognizer.process(frame(at: 2.02, contacts: [contact(2)])))
        XCTAssertFalse(sequentialRecognizer.process(frame(
            at: 2.04,
            contacts: [contact(2), contact(3)]
        )))
        XCTAssertFalse(sequentialRecognizer.process(frame(at: 2.08, contacts: [])))
    }

    func testNativeClickRewriteSuppressesSyntheticClickForSameEpisode() {
        let pipeline = MiddleClickTapPipeline(fingerCount: 3)
        XCTAssertFalse(pipeline.process(frame(
            at: 1.00,
            contacts: [contact(1), contact(2), contact(3)]
        )))

        XCTAssertEqual(
            pipeline.handleNativeMouseEvent(.down(.left)),
            .rewriteAsMiddle
        )
        XCTAssertEqual(
            pipeline.handleNativeMouseEvent(.up(.left)),
            .rewriteAsMiddle
        )
        XCTAssertFalse(pipeline.process(frame(at: 1.10, contacts: [])))
    }

    func testTapPipelineRequestsSyntheticClickWithoutNativeClick() {
        let pipeline = MiddleClickTapPipeline(fingerCount: 3)
        XCTAssertFalse(pipeline.process(frame(
            at: 1.00,
            contacts: [contact(1), contact(2), contact(3)]
        )))
        XCTAssertTrue(pipeline.process(frame(at: 1.10, contacts: [])))
    }

    func testStoreUsesLegacyDefaultsAndNormalizesFingerCount() {
        let storage = MiddleClickMemoryStorage()
        var store = MiddleClickStore(storage: storage)

        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.requiredFingerCount, 3)

        storage.values["middle-click.required-finger-count"] = 9
        store = MiddleClickStore(storage: storage)

        XCTAssertEqual(store.requiredFingerCount, 3)
    }

    func testActivateRestoresEnabledSessionAndFingerCount() {
        let storage = MiddleClickMemoryStorage()
        storage.values["middle-click.enabled"] = true
        storage.values["middle-click.required-finger-count"] = 5
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)

        plugin.activate(context: PluginRuntimeContext(pluginID: "middle-click"))

        XCTAssertEqual(session.activateCallCount, 1)
        XCTAssertEqual(session.requiredFingerCount, 5)
        XCTAssertTrue(plugin.store.isEnabled)
    }

    func testSettingsSwitchStartsAndStopsSessionWhenPermissionIsGranted() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)

        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        XCTAssertEqual(session.activateCallCount, 1)
        XCTAssertEqual(storage.values["middle-click.enabled"] as? Bool, true)
        XCTAssertTrue(plugin.store.isEnabled)

        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: false))

        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertEqual(storage.values["middle-click.enabled"] as? Bool, false)
        XCTAssertFalse(plugin.store.isEnabled)
    }

    func testCanonicalActionTogglesStateAndPublishesPresentation() async throws {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = ActionReference(key: definition.key)

        XCTAssertEqual(definition.key.actionID, "toggle")
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.title, "开启模拟鼠标中键")
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)

        let enable = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        ))
        let enableResult = await enable.result()
        XCTAssertEqual(enableResult, .succeeded())
        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.title, "关闭模拟鼠标中键")
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)

        let disable = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .unifiedSearch,
            mode: .foreground
        ))
        let disableResult = await disable.result()
        XCTAssertEqual(disableResult, .succeeded())
        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertEqual(session.activateCallCount, 1)
        XCTAssertEqual(session.deactivateCallCount, 1)
    }

    func testCanonicalActionRequiresAccessibilityBeforeEnabling() throws {
        let plugin = makePlugin(
            accessibilityTrusted: false,
            requestAccessibilityTrust: false
        )
        let reference = ActionReference(key: try XCTUnwrap(plugin.actionDefinitions.first).key)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: reference.key),
            ["accessibility"]
        )
    }

    func testCanonicalActionCanDisableAfterAccessibilityIsRevoked() throws {
        let storage = MiddleClickMemoryStorage()
        storage.values["middle-click.enabled"] = true
        let plugin = makePlugin(
            storage: storage,
            accessibilityTrusted: false,
            requestAccessibilityTrust: false
        )
        let reference = ActionReference(key: try XCTUnwrap(plugin.actionDefinitions.first).key)

        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)
        XCTAssertEqual(plugin.permissionRequirementIDs(for: reference.key), [])
    }

    func testTrackpadGestureClaimPausesAndRestoresEnabledSession() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        plugin.inputGestureConflictsDidChange([
            PluginInputGestureConflict(
                claim: PluginInputGestureClaim(id: "trackpad.tap.3", title: "Three-Finger Tap"),
                ownerPluginID: "trackpad-gestures",
                ownerPluginTitle: "Trackpad Gestures"
            ),
        ])

        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertNotNil(settingsRows(for: plugin).first?.error)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)

        plugin.inputGestureConflictsDidChange([])

        XCTAssertEqual(session.activateCallCount, 2)
        XCTAssertNil(settingsRows(for: plugin).first?.error)
    }

    func testDeniedPermissionKeepsFeatureOffAndRequestsGuidance() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(
            storage: storage,
            session: session,
            accessibilityTrusted: false,
            requestAccessibilityTrust: false
        )
        var requestedPermissionID: String?
        plugin.requestPermissionGuidance = { requestedPermissionID = $0 }

        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        XCTAssertEqual(session.activateCallCount, 0)
        XCTAssertNil(storage.values["middle-click.enabled"])
        XCTAssertEqual(requestedPermissionID, "accessibility")
        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertNotNil(settingsRows(for: plugin).first?.error)
    }

    func testFingerCountSettingUpdatesStorageAndRunningSession() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        plugin.handleSettingsAction(.setSelection(controlID: "finger-count", optionID: "4"))

        XCTAssertEqual(plugin.store.requiredFingerCount, 4)
        XCTAssertEqual(storage.values["middle-click.required-finger-count"] as? Int, 4)
        XCTAssertEqual(session.requiredFingerCount, 4)
    }

    func testInvalidFingerCountSettingIsIgnored() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)

        plugin.handleSettingsAction(.setSelection(controlID: "finger-count", optionID: "2"))

        XCTAssertEqual(plugin.store.requiredFingerCount, 3)
        XCTAssertNil(storage.values["middle-click.required-finger-count"])
        XCTAssertEqual(session.requiredFingerCount, 3)
    }

    func testPermissionRevocationStopsSessionAndTurnsFeatureOff() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        var isTrusted = true
        let plugin = makePlugin(
            storage: storage,
            session: session,
            accessibilityTrustedProvider: { isTrusted }
        )
        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        isTrusted = false
        plugin.refreshAccessibilityPermission()

        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertEqual(storage.values["middle-click.enabled"] as? Bool, false)
        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
    }

    func testSettingsPageUsesValidPluginKitV4Form() throws {
        let plugin = makePlugin()
        let page = try XCTUnwrap(plugin.settingsPage)

        XCTAssertEqual(page.body.layout, .form)
        XCTAssertNoThrow(try PluginSettingsValidator.validate(page))
        XCTAssertEqual(plugin.metadata.title, "模拟鼠标中键")

        let rows = settingsRows(for: plugin)
        XCTAssertEqual(rows.map(\.id), ["enabled", "finger-count"])
        guard case let .toggle(isOn) = rows.first?.control else {
            return XCTFail("Expected settings to start with the enable toggle")
        }
        XCTAssertFalse(isOn)
    }

    func testSettingsToggleTitleFollowsRuntimeLanguageAfterPluginCreation() throws {
        let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
        let originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiddleClickLocalizationTests-\(UUID().uuidString).bundle")
        defer {
            if let originalPreference {
                UserDefaults.standard.set(originalPreference, forKey: preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            }
            PluginRuntimeLocalization.source.setPreference(originalPreference)
            try? FileManager.default.removeItem(at: bundleURL)
        }

        let bundle = try makeLocalizationBundle(at: bundleURL)
        PluginRuntimeLocalization.source.setPreference("en")
        let plugin = makePlugin(localization: PluginLocalization(bundle: bundle))
        XCTAssertEqual(plugin.metadata.title, "Middle Click")
        XCTAssertEqual(settingsRows(for: plugin).first?.title, "Middle Click")

        PluginRuntimeLocalization.source.setPreference("zh-Hans")

        // Metadata was captured when the plugin was created, but settings must resolve against
        // the current app language each time the host rebuilds the page.
        XCTAssertEqual(plugin.metadata.title, "Middle Click")
        XCTAssertEqual(settingsRows(for: plugin).first?.title, "模拟鼠标中键")
    }

    func testRuntimeResolvesRequiredMultitouchSymbolsDynamically() {
        XCTAssertNotNil(MiddleClickMultitouchRuntime.load())
    }

    private func makePlugin(
        storage: MiddleClickMemoryStorage? = nil,
        session: MockMiddleClickSession? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        accessibilityTrusted: Bool = true,
        requestAccessibilityTrust: Bool = true,
        accessibilityTrustedProvider: (() -> Bool)? = nil
    ) -> MiddleClickPlugin {
        let storage = storage ?? MiddleClickMemoryStorage()
        let session = session ?? MockMiddleClickSession()
        return MiddleClickPlugin(
            context: PluginRuntimeContext(pluginID: "middle-click", storage: storage),
            localization: localization,
            makeSession: { session },
            accessibilityTrusted: {
                accessibilityTrustedProvider?() ?? accessibilityTrusted
            },
            requestAccessibilityTrust: { _ in requestAccessibilityTrust }
        )
    }

    private func makeLocalizationBundle(at bundleURL: URL) throws -> Bundle {
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "cc.ggbond.mactools.tests.middle-click-localization",
            "CFBundleLocalizations": ["en", "zh-Hans"],
            "CFBundleName": "MiddleClickLocalizationTests",
            "CFBundlePackageType": "BNDL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let stringsByLanguage: [String: [String: String]] = [
            "en": [
                "metadata.title": "Middle Click",
                "metadata.description": "Turn trackpad taps into middle clicks.",
                "settings.section.title": "Settings",
            ],
            "zh-Hans": [
                "metadata.title": "模拟鼠标中键",
                "metadata.description": "触控板轻点 → 模拟鼠标中键",
                "settings.section.title": "设置",
            ],
        ]
        for (language, strings) in stringsByLanguage {
            let localizationURL = resourcesURL.appendingPathComponent(
                "\(language).lproj",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: localizationURL,
                withIntermediateDirectories: true
            )
            let stringsData = try PropertyListSerialization.data(
                fromPropertyList: strings,
                format: .binary,
                options: 0
            )
            try stringsData.write(to: localizationURL.appendingPathComponent("Localizable.strings"))
        }

        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func settingsRows(for plugin: MiddleClickPlugin) -> [PluginSettingsRow] {
        guard case let .form(sections) = plugin.settingsPage?.body,
              case let .rows(rows) = sections.first?.content
        else {
            XCTFail("Expected declarative settings rows")
            return []
        }
        return rows
    }

    private func contact(
        _ identifier: Int,
        x: Double? = nil,
        y: Double = 0.50
    ) -> MiddleClickContactSnapshot {
        MiddleClickContactSnapshot(
            identifier: identifier,
            x: x ?? (0.30 + Double(identifier) * 0.10),
            y: y
        )
    }

    private func frame(
        deviceID: UInt64 = 1,
        at timestamp: TimeInterval,
        contacts: [MiddleClickContactSnapshot]
    ) -> MiddleClickContactFrame {
        MiddleClickContactFrame(
            deviceID: deviceID,
            timestamp: timestamp,
            contacts: contacts
        )
    }
}
