import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarStatusItemExpandedInterfaceTests: XCTestCase {
    private typealias Adapter = MenuBarStatusItemExpandedInterfaceAdapter

    func testSelectorConstantsMatchRuntimeLiterals() {
        XCTAssertEqual(Adapter.delegateSetterSelectorName, "setExpandedInterfaceDelegate:")
        XCTAssertEqual(Adapter.delegateGetterKey, "expandedInterfaceDelegate")
        XCTAssertEqual(Adapter.sessionDidBeginSelectorName, "statusItem:didBeginExpandedInterfaceSession:")
        XCTAssertEqual(Adapter.sessionDidEndSelectorName, "statusItemDidEndExpandedInterfaceSession:animated:")
        XCTAssertEqual(Adapter.sessionCancelSelectorName, "cancel")
    }

    func testCallbacksForwardSessionAndAnimatedFlag() {
        typealias DidEndFunction = @convention(c) (NSObject, Selector, NSStatusItem, ObjCBool) -> Void

        let adapter = Adapter()
        let item = makeDetachedStatusItem()
        let session = NSObject()
        var receivedSession: NSObject?
        var receivedAnimated: Bool?
        adapter.onSessionBegin = { receivedSession = $0 }
        adapter.onSessionEnd = { receivedAnimated = $0 }

        _ = adapter.perform(
            NSSelectorFromString(Adapter.sessionDidBeginSelectorName),
            with: item,
            with: session
        )

        let selector = NSSelectorFromString(Adapter.sessionDidEndSelectorName)
        let callback = unsafeBitCast(adapter.method(for: selector), to: DidEndFunction.self)
        callback(adapter, selector, item, ObjCBool(true))

        XCTAssertTrue(receivedSession === session)
        XCTAssertEqual(receivedAnimated, true)
    }

    func testCancelInvokesCancelWhenSessionResponds() {
        let session = RecordingCancellableSession()
        Adapter.cancel(session: session)
        XCTAssertEqual(session.cancelCount, 1)
    }

    func testCoordinatorClosePaths() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        var directDismissCount = 0

        coordinator.requestClose(
            cancel: { _ in XCTFail("no expanded-interface session should be cancelled") },
            directDismiss: { directDismissCount += 1 }
        )
        XCTAssertEqual(directDismissCount, 1)

        let session = NSObject()
        coordinator.sessionDidBegin(session)
        var cancelledSession: NSObject?
        coordinator.requestClose(
            cancel: {
                XCTAssertNil(coordinator.activeSession)
                cancelledSession = $0
            },
            directDismiss: { XCTFail("active expanded-interface sessions must close through cancel") }
        )
        XCTAssertTrue(cancelledSession === session)
    }

    func testSessionDidEndDismissesOnceAndPreventsReentry() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        coordinator.sessionDidBegin(NSObject())

        var dismissCount = 0
        coordinator.sessionDidEnd {
            dismissCount += 1
            XCTAssertNil(coordinator.activeSession)
            coordinator.sessionDidEnd { dismissCount += 1 }
        }

        XCTAssertEqual(dismissCount, 1)
    }

    private func makeDetachedStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSStatusBar.system.removeStatusItem(item)
        return item
    }
}

private final class RecordingCancellableSession: NSObject {
    private(set) var cancelCount = 0

    @objc func cancel() {
        cancelCount += 1
    }
}
