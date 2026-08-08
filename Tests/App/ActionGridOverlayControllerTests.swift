import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionGridOverlayControllerTests: XCTestCase {
    private let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
    private var originalPreference: String?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        PluginRuntimeLocalization.source.setPreference("en")
    }

    override func tearDown() {
        PluginRuntimeLocalization.source.setPreference(originalPreference)
        originalPreference = nil
        super.tearDown()
    }

    func testGeometryClampsGridToPointerDisplayVisibleFrame() {
        let visible = CGRect(x: 1_000, y: 200, width: 700, height: 500)
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: CGPoint(x: 1_680, y: 210),
            visibleFrame: visible,
            itemCount: 9
        )

        XCTAssertTrue(visible.insetBy(dx: 9, dy: 9).contains(frame))
        XCTAssertEqual(ActionGridOverlayGeometry.columnCount(for: 6), 3)
        XCTAssertEqual(ActionGridOverlayGeometry.columnCount(for: 7), 3)
    }

    func testGeometryPlacesCenterCellAtPointerWhenDisplayHasRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let pointer = CGPoint(x: 720, y: 450)
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: pointer,
            visibleFrame: visible,
            itemCount: 9
        )

        XCTAssertEqual(frame.midX, pointer.x, accuracy: 0.001)
        XCTAssertEqual(frame.midY, pointer.y, accuracy: 0.001)
    }

    func testGeometryMovesRelativeToPointerToRemainFullyVisible() {
        let visible = CGRect(x: 1_000, y: 200, width: 700, height: 500)
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: CGPoint(x: visible.maxX - 1, y: visible.maxY - 1),
            visibleFrame: visible,
            itemCount: 9
        )

        XCTAssertEqual(frame.maxX, visible.maxX - 10, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, visible.maxY - 10, accuracy: 0.001)
        XCTAssertTrue(visible.insetBy(dx: 9, dy: 9).contains(frame))
    }

    func testKeyboardNavigationUsesStableRowMajorPositions() {
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 0, direction: .left, itemCount: 6, columns: 2), 0)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 0, direction: .right, itemCount: 6, columns: 2), 1)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 1, direction: .right, itemCount: 6, columns: 2), 1)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 1, direction: .down, itemCount: 6, columns: 2), 3)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 5, direction: .down, itemCount: 6, columns: 2), 5)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 53, characters: nil), .dismiss)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 36, characters: nil), .activateSelected)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 123, characters: nil), .move(.left))
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 0, characters: "7"), .select(7))
        XCTAssertNil(ActionGridKeyCommand.resolve(keyCode: 0, characters: "0"))
    }

    func testKeyboardNavigationPreservesSparseGridSlots() {
        let occupied: Set<Int> = [0, 2, 7]

        XCTAssertEqual(
            ActionGridKeyboardNavigation.nextOccupiedSlot(
                from: 0,
                direction: .right,
                occupiedSlots: occupied
            ),
            2
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.nextOccupiedSlot(
                from: 7,
                direction: .up,
                occupiedSlots: occupied
            ),
            7
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.nextOccupiedSlot(
                from: 2,
                direction: .left,
                occupiedSlots: occupied
            ),
            0
        )
    }

    func testKeyboardNavigationPrefersCenterThenNearestOccupiedSlot() {
        XCTAssertEqual(
            ActionGridKeyboardNavigation.preferredInitialSlot(
                occupiedSlots: [0, 1, 4, 8]
            ),
            4
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.preferredInitialSlot(
                occupiedSlots: [0, 1, 8]
            ),
            1
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.preferredInitialSlot(occupiedSlots: []),
            0
        )
    }

    func testModelSelectsCenterEntryWhenPresentedAndInsideFolders() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: entry.customTitle ?? entry.id,
                    ownerTitle: "Owner",
                    systemImage: "bolt",
                    availability: .available,
                    children: entry.children
                )
            },
            executor: { _ in .completed(.succeeded()) }
        )
        let children = [
            ActionGridPresentationEntry(id: "child-top", reference: reference, slotIndex: 0),
            ActionGridPresentationEntry(id: "child-center", reference: reference, slotIndex: 4),
        ]
        model.update([
            ActionGridPresentationEntry(id: "top", reference: reference, slotIndex: 0),
            ActionGridPresentationEntry(
                id: "folder",
                folderTitle: "Folder",
                children: children,
                slotIndex: 4
            ),
        ])

        XCTAssertEqual(model.selectedIndex, 4)
        model.activateSelected()
        XCTAssertEqual(model.navigationTitle, "Folder")
        XCTAssertEqual(model.selectedIndex, 4)
    }

    func testPointerActivationWaitsForGestureReleaseGracePeriod() {
        let presentedAt: TimeInterval = 10

        XCTAssertFalse(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt,
            presentationUptime: presentedAt,
            source: .globalShortcut
        ))
        XCTAssertFalse(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.34,
            presentationUptime: presentedAt,
            source: .globalShortcut
        ))
        XCTAssertTrue(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.36,
            presentationUptime: presentedAt,
            source: .globalShortcut
        ))
        XCTAssertFalse(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.79,
            presentationUptime: presentedAt,
            source: .trackpadGesture
        ))
        XCTAssertTrue(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.81,
            presentationUptime: presentedAt,
            source: .trackpadGesture
        ))
    }

    func testAccessibilityLabelIncludesOwnerAvailabilityAndDisabledReason() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        let available = ResolvedActionGridEntry(
            id: "available",
            reference: reference,
            title: "运行",
            ownerTitle: "测试插件",
            systemImage: "bolt",
            availability: .available
        )
        let unavailable = ResolvedActionGridEntry(
            id: "unavailable",
            reference: reference,
            title: "运行",
            ownerTitle: "测试插件",
            systemImage: "bolt",
            availability: .unavailable("需要权限。")
        )

        XCTAssertEqual(available.accessibilityLabel, "运行, 测试插件, and Available")
        XCTAssertEqual(unavailable.accessibilityLabel, "运行, 测试插件, and 需要权限。")
    }

    func testRepeatedPresentationReusesOneOverlayPanel() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let entry = ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(key: ActionKey(providerID: "missing", actionID: "run"))
        )

        XCTAssertTrue(controller.present(entries: [entry]))
        XCTAssertTrue(
            controller.present(
                entries: [
                    ActionGridPresentationEntry(
                        id: "replacement",
                        reference: ActionReference(
                            key: ActionKey(providerID: "missing", actionID: "replacement")
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(controller.presentedEntryIDs, ["one"])
        XCTAssertEqual(
            NSApp.windows.filter { $0.identifier == ActionGridOverlayController.panelIdentifier }.count,
            1
        )
    }

    func testRepeatedCloseAndPresentationKeepsOneLiveOverlayPanel() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let entry = ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(key: ActionKey(providerID: "missing", actionID: "run"))
        )

        for _ in 0 ..< 20 {
            XCTAssertTrue(controller.present(entries: [entry]))
            controller.close(restoringFocus: false)
        }

        XCTAssertFalse(controller.isShown)
        XCTAssertTrue(NSApp.windows.filter {
            $0.identifier == ActionGridOverlayController.panelIdentifier && $0.isVisible
        }.isEmpty)
    }

    func testPresentedPanelSupportsSpacesAndEscapeDismissal() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }

        XCTAssertTrue(controller.present(entries: [testEntry()]))
        let behavior = try XCTUnwrap(controller.presentedPanelCollectionBehavior)
        XCTAssertTrue(behavior.contains(.moveToActiveSpace))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.transient))
        XCTAssertTrue(behavior.contains(.ignoresCycle))

        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        XCTAssertTrue(controller.processKeyEvent(escape))
        XCTAssertFalse(controller.isShown)
    }

    func testFolderNavigationResizesPanelForNestedGridAndBack() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "run")
        )
        let folder = ActionGridPresentationEntry(
            id: "folder",
            folderTitle: "Folder",
            children: [
                ActionGridPresentationEntry(id: "top", reference: reference, slotIndex: 0),
                ActionGridPresentationEntry(id: "middle", reference: reference, slotIndex: 4),
                ActionGridPresentationEntry(id: "bottom", reference: reference, slotIndex: 8),
            ]
        )

        XCTAssertTrue(controller.present(entries: [folder]))
        let rootFrame = try XCTUnwrap(controller.presentedPanelFrame)
        XCTAssertTrue(controller.processKeyEvent(try keyEvent(keyCode: 36, characters: "\r")))
        let nestedFrame = try XCTUnwrap(controller.presentedPanelFrame)
        XCTAssertGreaterThan(nestedFrame.height, rootFrame.height)
        XCTAssertEqual(
            nestedFrame.height,
            ActionGridOverlayGeometry.contentSize(
                for: 9,
                includesNavigationHeader: true
            ).height
        )
        XCTAssertGreaterThan(
            nestedFrame.height,
            ActionGridOverlayGeometry.contentSize(for: 9).height
        )

        XCTAssertTrue(controller.processKeyEvent(try keyEvent(keyCode: 53, characters: "\u{1B}")))
        XCTAssertEqual(
            try XCTUnwrap(controller.presentedPanelFrame?.height),
            rootFrame.height,
            accuracy: 1
        )
        XCTAssertTrue(controller.isShown)
    }

    func testPointerDismissalKeepsInsideClickAndClosesForOutsideClick() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }

        XCTAssertTrue(controller.present(entries: [testEntry()]))
        let frame = try XCTUnwrap(controller.presentedPanelFrame)
        controller.dismissIfPointerIsOutside(
            CGPoint(x: frame.midX, y: frame.midY)
        )
        XCTAssertTrue(controller.isShown)

        controller.dismissIfPointerIsOutside(
            CGPoint(x: frame.maxX + 1, y: frame.maxY + 1)
        )
        XCTAssertFalse(controller.isShown)
    }

    func testDashboardActionExecutesThroughOverlayAndDismisses() async throws {
        let host = makePluginHostForTests(plugins: [])
        var presentationRequests: [AppPresentationRequest] = []
        host.appPresentationHandler = { presentationRequests.append($0) }
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let entry = ActionGridPresentationEntry(
            id: "dashboard",
            reference: ActionReference(
                key: ActionKey(
                    providerID: "mactools",
                    actionID: AppShortcutAction.toggleDashboard.rawValue
                )
            )
        )

        XCTAssertTrue(controller.present(entries: [entry]))
        let enter = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        XCTAssertTrue(controller.processKeyEvent(enter))

        for _ in 0 ..< 50 where presentationRequests.isEmpty || controller.isShown {
            await Task.yield()
        }

        XCTAssertEqual(presentationRequests, [.toggleDashboard])
        XCTAssertFalse(controller.isShown)
    }

    func testAccessibilityPolicyHonorsReducedMotionAndTransparency() {
        let standard = ActionGridOverlayAccessibilityPolicy(
            reduceMotion: false,
            reduceTransparency: false
        )
        XCTAssertTrue(standard.animatesSelection)
        XCTAssertTrue(standard.usesMaterialBackground)

        let reduced = ActionGridOverlayAccessibilityPolicy(
            reduceMotion: true,
            reduceTransparency: true
        )
        XCTAssertFalse(reduced.animatesSelection)
        XCTAssertFalse(reduced.usesMaterialBackground)
    }

    func testOverlayRootUsesSelectedLocaleDirection() {
        XCTAssertEqual(
            ActionGridOverlayRootView.layoutDirection(for: Locale(identifier: "ar")),
            .rightToLeft
        )
        XCTAssertEqual(
            ActionGridOverlayRootView.layoutDirection(for: Locale(identifier: "de")),
            .leftToRight
        )
    }

    func testModelReresolvesVisibleEntriesAfterRuntimeLanguageChange() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        var title = "English"
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: title,
                    ownerTitle: "Owner",
                    systemImage: "bolt",
                    availability: .available
                )
            },
            executor: { _ in .completed(.succeeded()) }
        )
        model.update([ActionGridPresentationEntry(id: "entry", reference: reference)])
        XCTAssertEqual(model.entries.first?.title, "English")

        title = "العربية"
        model.refreshLocalization()

        XCTAssertEqual(model.entries.first?.title, "العربية")
    }

    func testUnavailableEntryKeepsGridOpenAndSuccessfulExecutionRequestsDismissal() async {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        var executionCount = 0
        var dismissed = false
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: "运行",
                    ownerTitle: "测试",
                    systemImage: "bolt",
                    availability: entry.id == "available" ? .available : .unavailable("当前不可用。")
                )
            },
            executor: { _ in
                executionCount += 1
                return .completed(.succeeded())
            }
        )
        model.onSuccessfulExecution = { dismissed = true }
        model.update([
            ActionGridPresentationEntry(id: "unavailable", reference: reference, slotIndex: 4),
            ActionGridPresentationEntry(id: "available", reference: reference, slotIndex: 1),
        ])

        model.activateSelected()
        XCTAssertEqual(model.feedback, "当前不可用。")
        XCTAssertEqual(executionCount, 0)
        XCTAssertFalse(dismissed)

        model.select(number: 2)
        for _ in 0 ..< 20 where model.isExecuting {
            await Task.yield()
        }
        XCTAssertEqual(executionCount, 1)
        XCTAssertTrue(dismissed)
    }

    func testFolderNavigationStaysInOverlayAndDoesNotExecuteFolderSentinel() {
        let actionReference = ActionReference(
            key: ActionKey(providerID: "lock-screen", actionID: "lock")
        )
        let child = ActionGridPresentationEntry(id: "lock", reference: actionReference)
        let folder = ActionGridPresentationEntry(
            id: "system",
            folderTitle: "System",
            children: [child]
        )
        var executed: [ActionReference] = []
        let model = ActionGridOverlayModel(
            resolver: { entry in
                if let children = entry.children {
                    return ResolvedActionGridEntry(
                        id: entry.id,
                        reference: entry.reference,
                        title: entry.customTitle ?? "Folder",
                        ownerTitle: "Folder",
                        systemImage: "folder.fill",
                        availability: .available,
                        children: children
                    )
                }
                return ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: "Lock Screen",
                    ownerTitle: "System",
                    systemImage: "lock",
                    availability: .available
                )
            },
            executor: {
                executed.append($0)
                return .completed(.succeeded())
            }
        )
        model.update([folder])

        model.activateSelected()
        XCTAssertEqual(model.navigationTitle, "System")
        XCTAssertEqual(model.entries.map(\.title), ["Lock Screen"])
        XCTAssertTrue(executed.isEmpty)

        XCTAssertTrue(model.navigateBack())
        XCTAssertNil(model.navigationTitle)
        XCTAssertEqual(model.entries.map(\.title), ["System"])
        XCTAssertFalse(model.navigateBack())
    }

    private func testEntry() -> ActionGridPresentationEntry {
        ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(
                key: ActionKey(providerID: "missing", actionID: "run")
            )
        )
    }

    private func keyEvent(keyCode: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
