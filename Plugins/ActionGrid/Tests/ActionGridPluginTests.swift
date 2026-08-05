import AppKit
import MacToolsPluginKit
import SwiftUI
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

    func testRenderedSettingsRowExposesDistinctOperableAccessibilityElements() throws {
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(
                pluginID: "action-grid",
                storage: ActionGridTestStorage()
            )
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "lock-screen", actionID: "execute")
        )
        let item = ActionSurfaceCatalogItem(
            reference: reference,
            title: "锁定屏幕",
            subtitle: nil,
            ownerTitle: "MacTools",
            systemImage: "lock",
            availability: .available,
            isSafe: true,
            canOpenOwner: true
        )
        let replacement = ActionSurfaceCatalogItem(
            reference: ActionReference(
                key: ActionKey(providerID: "lock-screen", actionID: "alternate")
            ),
            title: "备用操作",
            subtitle: nil,
            ownerTitle: "MacTools",
            systemImage: "bolt",
            availability: .available,
            isSafe: true,
            canOpenOwner: false
        )
        var openedOwner: ActionReference?
        plugin.actionGridHostContext = ActionGridHostContext(
            catalog: { [item, replacement] },
            item: { $0 == reference ? item : nil },
            migrate: { $0 },
            openOwner: {
                openedOwner = $0
                return true
            },
            canPresent: { true },
            present: { _ in true }
        )
        XCTAssertTrue(plugin.store.add(reference: reference))

        let entryID = try XCTUnwrap(plugin.store.entries.first?.id)
        let entry = try XCTUnwrap(plugin.store.entries.first)
        let hostingView = NSHostingView(
            rootView: ActionGridEntryRow(plugin: plugin, store: plugin.store, entry: entry)
                .frame(width: 800, height: 90)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 90)
        hostingView.layoutSubtreeIfNeeded()

        let accessibilityRoot = try XCTUnwrap(
            NSAccessibility.unignoredDescendant(of: hostingView) as? NSObject
        )
        let elements = accessibilityDescendants(of: accessibilityRoot)
        let diagnostics = elements.map {
            "\(String(reflecting: type(of: $0))):"
                + "\(accessibilityRole(of: $0)?.rawValue ?? "nil"):"
                + "\(accessibilityIdentifier(of: $0) ?? "nil"):"
                + "\(accessibilityLabel(of: $0) ?? "nil")"
        }
        var identifiedElements: [String: NSObject] = [:]
        for element in elements {
            guard let identifier = accessibilityIdentifier(of: element),
                  identifiedElements[identifier] == nil else { continue }
            identifiedElements[identifier] = element
        }

        let prefix = "mactools.action-grid.entry.\(entryID.uuidString)"
        let expectations = [
            ("\(prefix).settings", "设置“锁定屏幕”"),
            ("\(prefix).replace", "替换“锁定屏幕”"),
            ("\(prefix).remove", "移除“锁定屏幕”"),
        ]
        for (identifier, label) in expectations {
            let element = try XCTUnwrap(identifiedElements[identifier], "\(diagnostics)")
            XCTAssertEqual(accessibilityLabel(of: element), label)
            XCTAssertTrue(isOperableControl(element), "\(identifier): \(diagnostics)")
        }

        let settingsButton = try XCTUnwrap(
            identifiedElements["\(prefix).settings"] as? NSButton
        )
        XCTAssertTrue(sendControlAction(settingsButton))
        XCTAssertEqual(openedOwner, reference)

        let replacementButton = try XCTUnwrap(
            identifiedElements["\(prefix).replace"] as? NSPopUpButton
        )
        let replacementItem = try XCTUnwrap(
            replacementButton.menu?.items.first { $0.title == replacement.title }
        )
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(replacementItem.action),
            to: replacementItem.target,
            from: replacementItem
        ))
        XCTAssertEqual(plugin.store.entries.first?.reference, replacement.reference)

        let removeButton = try XCTUnwrap(
            identifiedElements["\(prefix).remove"] as? NSButton
        )
        XCTAssertTrue(sendControlAction(removeButton))
        XCTAssertTrue(plugin.store.entries.isEmpty)
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

private func accessibilityDescendants(of root: NSObject) -> [NSObject] {
    var result: [NSObject] = []
    var pending: [NSObject] = [root]
    var visited: Set<ObjectIdentifier> = []
    while let element = pending.popLast() {
        guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
        result.append(element)
        pending.append(contentsOf: accessibilityChildren(of: element))
    }
    return result
}

private func accessibilityChildren(of element: NSObject) -> [NSObject] {
    if let view = element as? NSView {
        return (view.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
            + view.subviews
    }
    if let accessibilityElement = element as? NSAccessibilityElement {
        return (accessibilityElement.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
    }
    return []
}

private func accessibilityLabel(of element: NSObject) -> String? {
    if let view = element as? NSView {
        return view.accessibilityLabel()
    }
    if let accessibilityElement = element as? NSAccessibilityElement {
        return accessibilityElement.accessibilityLabel()
    }
    return nil
}

private func accessibilityRole(of element: NSObject) -> NSAccessibility.Role? {
    if let view = element as? NSView {
        return view.accessibilityRole()
    }
    if let accessibilityElement = element as? NSAccessibilityElement {
        return accessibilityElement.accessibilityRole()
    }
    return nil
}

private func accessibilityIdentifier(of element: NSObject) -> String? {
    if let view = element as? NSView {
        return view.accessibilityIdentifier()
    }
    if let accessibilityElement = element as? NSAccessibilityElement {
        return accessibilityElement.accessibilityIdentifier()
    }
    return nil
}

private func isOperableControl(_ element: NSObject) -> Bool {
    guard let control = element as? NSControl, control.isEnabled else { return false }
    if let popUpButton = control as? NSPopUpButton {
        return popUpButton.menu?.items.contains {
            $0.target != nil && $0.action != nil
        } == true
    }
    return control.target != nil && control.action != nil
}

private func sendControlAction(_ control: NSControl) -> Bool {
    guard let action = control.action else { return false }
    return NSApp.sendAction(action, to: control.target, from: control)
}
