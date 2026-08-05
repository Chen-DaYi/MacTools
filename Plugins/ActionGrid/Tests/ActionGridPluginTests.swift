import AppKit
import MacToolsPluginKit
import XCTest
@testable import ActionGridPlugin

@MainActor
final class ActionGridPluginTests: XCTestCase {
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
            present: {
                presented = $0
                return true
            }
        )
        XCTAssertTrue(plugin.store.add(reference: target))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key, ActionGridPlugin.showActionKey)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
        XCTAssertTrue(plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable)

        let handle = try plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .globalShortcut,
                mode: .foreground
            )
        )
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(presented.map(\.reference), [target])
        XCTAssertTrue(plugin.openOwner(for: target))
        XCTAssertEqual(openedOwner, target)
        XCTAssertEqual(
            plugin.actionSurfaceAssignmentSummary(for: target)?.detail,
            "第 1 个条目"
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
            present: { _ in XCTFail("Presenter should not be called"); return false }
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
