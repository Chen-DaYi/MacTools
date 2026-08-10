import AppKit
import MacToolsPluginKit
import XCTest
@testable import ActionGridPlugin

@MainActor
final class ActionGridPluginTests: XCTestCase {
    func testLocalizedAccessibilityCopyUsesRuntimePluginLanguage() throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("ActionGridTests.bundle", isDirectory: true)
        let languageURL = bundleURL.appendingPathComponent("en.lproj", isDirectory: true)
        let arabicLanguageURL = bundleURL.appendingPathComponent("ar.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: arabicLanguageURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try [
            "\"%@，%@，%@\" = \"%@, %@, %@\";",
            "\"设置“%@”\" = \"Settings for “%@”\";",
            "\"替换“%@”\" = \"Replace “%@”\";",
            "\"移除“%@”\" = \"Remove “%@”\";",
            "\"设置\" = \"Settings\";",
            "\"替换\" = \"Replace\";",
            "\"打开操作提供者设置\" = \"Open action provider settings\";",
            "\"选择其他操作替换此条目\" = \"Choose another action for this entry\";",
            "\"从操作网格移除此条目\" = \"Remove this entry from Action Grid\";",
            "\"metadata.title\" = \"Action Grid\";",
            "\"metadata.description\" = \"Open favorite actions near the pointer\";",
        ].joined(separator: "\n").write(
            to: languageURL.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        try [
            "\"metadata.title\" = \"شبكة الإجراءات\";",
            "\"metadata.description\" = \"افتح شبكة إجراءات مفضلة بالقرب من المؤشر\";",
            "\"第 %d 个条目\" = \"الإدخال %d\";",
        ].joined(separator: "\n").write(
            to: arabicLanguageURL.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )

        PluginRuntimeLocalization.source.setPreference("en")
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(
                pluginID: "action-grid",
                resourceBundle: try XCTUnwrap(Bundle(url: bundleURL)),
                storage: ActionGridTestStorage()
            )
        )
        let accessibility = ActionGridEntryAccessibility(
            title: "Lock Screen",
            owner: "MacTools",
            availability: "Available",
            copy: plugin.accessibilityCopy
        )

        XCTAssertEqual(accessibility.summaryLabel, "Lock Screen, MacTools, Available")
        XCTAssertEqual(accessibility.settingsLabel, "Settings for “Lock Screen”")
        XCTAssertEqual(accessibility.replaceLabel, "Replace “Lock Screen”")
        XCTAssertEqual(accessibility.removeLabel, "Remove “Lock Screen”")
        XCTAssertEqual(accessibility.copy.settingsButtonTitle, "Settings")
        XCTAssertEqual(accessibility.copy.replacementMenuTitle, "Replace")
        XCTAssertEqual(plugin.settingsPage?.description, "Open favorite actions near the pointer")
        let reference = ActionReference(key: ActionKey(providerID: "example", actionID: "run"))
        XCTAssertTrue(plugin.store.add(reference: reference))
        XCTAssertEqual(
            plugin.actionSurfaceAssignmentSummary(for: reference)?.surfaceTitle,
            "Action Grid"
        )

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(
            plugin.settingsPage?.description,
            "افتح شبكة إجراءات مفضلة بالقرب من المؤشر"
        )
        XCTAssertEqual(
            plugin.actionSurfaceAssignmentSummary(for: reference)?.surfaceTitle,
            "شبكة الإجراءات"
        )
    }

    func testSettingsRowExposesDistinctAccessibleOperations() {
        let accessibility = ActionGridEntryAccessibility(
            title: "锁定屏幕",
            owner: "MacTools",
            availability: "可用"
        )

        XCTAssertEqual(accessibility.summaryLabel, "锁定屏幕，MacTools，可用")
        XCTAssertEqual(accessibility.settingsLabel, "设置“锁定屏幕”")
        XCTAssertEqual(accessibility.replaceLabel, "替换“锁定屏幕”")
        XCTAssertEqual(accessibility.removeLabel, "移除“锁定屏幕”")
        XCTAssertEqual(
            Set([
                accessibility.summaryLabel,
                accessibility.settingsLabel,
                accessibility.replaceLabel,
                accessibility.removeLabel,
            ]).count,
            4
        )
    }

    func testActionPickerDistinguishesAdaptiveToggleFromExplicitActions() {
        let toggleReference = ActionReference(
            key: ActionKey(providerID: "keep-awake", actionID: "toggle")
        )
        let toggleItem = ActionSurfaceCatalogItem(
            reference: toggleReference,
            title: "Turn Off Keep Awake",
            subtitle: "On · Never",
            ownerTitle: "Keep Awake",
            systemImage: "moon",
            availability: .available,
            isSafe: true,
            presentationState: .active
        )
        let togglePresentation = ActionGridActionPickerPresentation(
            item: toggleItem,
            toggleLabel: "Toggle",
            nextActionDetail: "Next action: Turn Off Keep Awake"
        )

        XCTAssertEqual(togglePresentation.title, "Keep Awake")
        XCTAssertEqual(togglePresentation.detail, "Next action: Turn Off Keep Awake")
        XCTAssertEqual(togglePresentation.badge, "Toggle")

        let explicitItem = ActionSurfaceCatalogItem(
            reference: ActionReference(
                key: ActionKey(providerID: "keep-awake", actionID: "set-disabled")
            ),
            title: "Turn Off Keep Awake",
            subtitle: nil,
            ownerTitle: "Keep Awake",
            systemImage: "moon",
            availability: .available,
            isSafe: true
        )
        let explicitPresentation = ActionGridActionPickerPresentation(
            item: explicitItem,
            toggleLabel: "Toggle",
            nextActionDetail: "Next action: Turn Off Keep Awake"
        )

        XCTAssertEqual(explicitPresentation.title, "Turn Off Keep Awake")
        XCTAssertEqual(explicitPresentation.detail, "Keep Awake")
        XCTAssertNil(explicitPresentation.badge)
    }

    func testNativeSettingsControlsExposeDistinctOperableAccessibilityElements() throws {
        let accessibility = ActionGridEntryAccessibility(
            title: "锁定屏幕",
            owner: "MacTools",
            availability: "可用"
        )
        let replacement = ActionReference(
            key: ActionKey(providerID: "lock-screen", actionID: "alternate")
        )
        var didOpenSettings = false
        var selectedReplacement: ActionReference?
        var didRemove = false
        let controls = ActionGridEntryControlsView.NativeView()
        controls.update(
            settingsAction: { didOpenSettings = true },
            replacementOptions: [
                ActionGridReplacementOption(title: "备用操作", reference: replacement),
            ],
            replaceAction: { selectedReplacement = $0 },
            removeAction: { didRemove = true },
            accessibility: accessibility,
            identifierPrefix: "mactools.action-grid.entry.test"
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = controls
        controls.frame = panel.contentView?.bounds ?? .zero
        controls.layoutSubtreeIfNeeded()
        defer {
            panel.contentView = nil
            panel.close()
        }

        let accessibilityChildren = NSAccessibility.unignoredChildren(
            from: try XCTUnwrap(controls.accessibilityChildren())
        ).compactMap { $0 as? NSControl }
        XCTAssertEqual(accessibilityChildren.count, 3)

        var controlsByIdentifier: [String: NSControl] = [:]
        for control in accessibilityChildren {
            controlsByIdentifier[control.accessibilityIdentifier()] = control
        }
        XCTAssertEqual(controlsByIdentifier.count, 3)

        let settingsButton = try XCTUnwrap(
            controlsByIdentifier["mactools.action-grid.entry.test.settings"] as? NSButton
        )
        XCTAssertEqual(settingsButton.accessibilityRole(), NSAccessibility.Role.button)
        XCTAssertEqual(settingsButton.accessibilityLabel(), accessibility.settingsLabel)
        XCTAssertTrue(settingsButton.isEnabled)
        XCTAssertNotNil(settingsButton.action)
        _ = settingsButton.accessibilityPerformPress()
        XCTAssertTrue(didOpenSettings)

        let replacementButton = try XCTUnwrap(
            controlsByIdentifier["mactools.action-grid.entry.test.replace"] as? NSPopUpButton
        )
        XCTAssertEqual(
            replacementButton.accessibilityRole(),
            NSAccessibility.Role.menuButton
        )
        XCTAssertEqual(replacementButton.accessibilityLabel(), accessibility.replaceLabel)
        XCTAssertTrue(replacementButton.isEnabled)
        let replacementItem = try XCTUnwrap(
            replacementButton.menu?.items.first { $0.title == "备用操作" }
        )
        XCTAssertNotNil(replacementItem.action)
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(replacementItem.action),
            to: replacementItem.target,
            from: replacementItem
        ))
        XCTAssertEqual(selectedReplacement, replacement)

        let removeButton = try XCTUnwrap(
            controlsByIdentifier["mactools.action-grid.entry.test.remove"] as? NSButton
        )
        XCTAssertEqual(removeButton.accessibilityRole(), NSAccessibility.Role.button)
        XCTAssertEqual(removeButton.accessibilityLabel(), accessibility.removeLabel)
        XCTAssertTrue(removeButton.isEnabled)
        XCTAssertNotNil(removeButton.action)
        _ = removeButton.accessibilityPerformPress()
        XCTAssertTrue(didRemove)
    }

    func testShowActionIsForegroundOnlyExternallyEligibleAndPresentsSavedEntries() async throws {
        let storage = ActionGridTestStorage()
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(pluginID: "action-grid", storage: storage)
        )
        let target = ActionReference(key: ActionKey(providerID: "target", actionID: "run"))
        var presented: [ActionGridPresentationEntry] = []
        var presentationSource: ActionExecutionSource?
        var openedOwner: ActionReference?
        plugin.actionGridHostContext = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            openOwner: {
                openedOwner = $0
                return true
            },
            canPresent: { true },
            present: { entries, source in
                presented = entries
                presentationSource = source
                return true
            }
        )
        XCTAssertTrue(plugin.store.add(reference: target, in: nil, at: 8))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key, ActionGridPlugin.showActionKey)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
        XCTAssertTrue(plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable)

        let handle = try plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .trackpadGesture,
                mode: .foreground
            )
        )
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(presented.map(\.reference), [target])
        XCTAssertEqual(presented.map(\.slotIndex), [8])
        XCTAssertEqual(presentationSource, .trackpadGesture)
        XCTAssertTrue(plugin.openOwner(for: target))
        XCTAssertEqual(openedOwner, target)
        XCTAssertEqual(
            plugin.actionSurfaceAssignmentSummary(for: target)?.detail,
            "第 9 个条目"
        )
    }

    func testShowActionIsUnavailableWithoutEntriesOrHostPresenterAndSelfEntryIsNeverPresented() async throws {
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(pluginID: "action-grid", storage: ActionGridTestStorage())
        )
        let showReference = ActionReference(key: ActionGridPlugin.showActionKey)
        XCTAssertFalse(plugin.actionAvailability(for: showReference).isAvailable)

        plugin.actionGridHostContext = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            canPresent: { true },
            present: { _, _ in XCTFail("Presenter should not be called"); return false }
        )
        XCTAssertTrue(plugin.store.add(reference: showReference))
        XCTAssertFalse(plugin.actionAvailability(for: showReference).isAvailable)
        let handle = try plugin.beginAction(
            ActionInvocation(reference: showReference, source: .manual, mode: .foreground)
        )
        let result = await handle.result()
        XCTAssertEqual(result, .failed(message: "无法显示操作网格。"))
    }
}
