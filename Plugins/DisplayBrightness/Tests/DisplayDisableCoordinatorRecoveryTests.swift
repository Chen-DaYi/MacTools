import CoreGraphics
import Foundation
import XCTest
import MacToolsPluginKit
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayDisableCoordinatorRecoveryTests: XCTestCase {
    func testTopologyReconcileRestoresBuiltInDisplayAfterExternalDisconnect() async {
        let fixture = makeDisabledDisplayFixture()

        fixture.service.onlineDisplays = [fixture.disabledBuiltIn]
        await fixture.coordinator.reconcileTopology()

        XCTAssertEqual(
            fixture.service.setEnabledCalls,
            [.init(displayID: fixture.disabledBuiltIn.id, enabled: true)]
        )
        XCTAssertNil(fixture.store.snapshot)
    }

    private func makeDisabledDisplayFixture() -> DisabledDisplayFixture {
        let disabledBuiltIn = DisplayDisableDisplay(
            id: 1,
            name: "Built-in Display",
            isBuiltin: true,
            isActive: false,
            isInMirrorSet: false,
            isVisibleToAppKit: false,
            vendorNumber: 0x610,
            modelNumber: 0xA050,
            serialNumber: 0x01
        )
        let external = DisplayDisableDisplay(
            id: 2,
            name: "External Display",
            isBuiltin: false,
            isActive: true,
            isInMirrorSet: false,
            isVisibleToAppKit: true,
            vendorNumber: 0x610,
            modelNumber: 0xA035,
            serialNumber: 0x99
        )
        let recoverySnapshot = DisplayDisableRecoverySnapshot(
            createdAt: Date(timeIntervalSince1970: 1),
            builtInDisplayID: disabledBuiltIn.id,
            vendorNumber: disabledBuiltIn.vendorNumber,
            modelNumber: disabledBuiltIn.modelNumber,
            serialNumber: disabledBuiltIn.serialNumber,
            survivorDisplayIDs: [external.id],
            survivorIdentities: [
                DisplaySurvivorIdentity(
                    id: external.id,
                    vendorNumber: external.vendorNumber,
                    modelNumber: external.modelNumber,
                    serialNumber: external.serialNumber
                )
            ],
            originalMainDisplayID: external.id
        )
        let service = WakeRecoveryDisplayDisableService(
            onlineDisplays: [disabledBuiltIn, external]
        )
        let store = WakeRecoveryDisplayDisableStore(snapshot: recoverySnapshot)
        let coordinator = DisplayDisableCoordinator(
            service: service,
            store: store,
            verificationSettleDelay: .zero,
            presentationPreparation: {}
        )

        return DisabledDisplayFixture(
            disabledBuiltIn: disabledBuiltIn,
            service: service,
            store: store,
            coordinator: coordinator
        )
    }
}

@MainActor
private struct DisabledDisplayFixture {
    let disabledBuiltIn: DisplayDisableDisplay
    let service: WakeRecoveryDisplayDisableService
    let store: WakeRecoveryDisplayDisableStore
    let coordinator: DisplayDisableCoordinator
}

@MainActor
private final class WakeRecoveryDisplayDisableStore: DisplayDisableStateStoring {
    var snapshot: DisplayDisableRecoverySnapshot?

    init(snapshot: DisplayDisableRecoverySnapshot?) {
        self.snapshot = snapshot
    }
}

@MainActor
private final class WakeRecoveryDisplayDisableService: DisplayDisableServicing {
    struct SetEnabledCall: Equatable {
        let displayID: CGDirectDisplayID
        let enabled: Bool
    }

    let isSupported = true
    var onlineDisplays: [DisplayDisableDisplay]
    private(set) var setEnabledCalls: [SetEnabledCall] = []

    init(onlineDisplays: [DisplayDisableDisplay]) {
        self.onlineDisplays = onlineDisplays
    }

    func listDisplays() -> [DisplayDisableDisplay] {
        onlineDisplays
    }

    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        setEnabledCalls.append(SetEnabledCall(displayID: displayID, enabled: enabled))
        onlineDisplays = onlineDisplays.map { display in
            guard display.id == displayID else { return display }
            return display
                .withActive(enabled)
                .withVisibleToAppKit(enabled)
        }
    }
}
