import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanPluginTests: XCTestCase {
    func testMetadataIdentifiesDiskCleanPlugin() {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        XCTAssertEqual(plugin.metadata.id, "disk-clean")
        XCTAssertEqual(plugin.metadata.title, "磁盘清理")
    }

    func testExpandedPanelExposesOnlyScanCleanAndOpenDetailsActions() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(
            controls.map(\.id),
            [
                DiskCleanPlugin.ControlID.scan,
                DiskCleanPlugin.ControlID.clean,
                DiskCleanPlugin.ControlID.openDetails
            ]
        )
        XCTAssertEqual(controls.map(\.actionTitle), ["扫描", "清理", "打开详情"])
        XCTAssertFalse(controls.contains { $0.id.hasPrefix("disk-clean-choice.") })
        XCTAssertFalse(controls.contains { $0.id == "disk-clean-test-mode" })
    }

    func testInvokingScanForwardsToController() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.scan))

        XCTAssertEqual(controller.scanCallCount, 1)
    }

    func testInvokingCleanForwardsAllCleanableCandidates() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = DiskCleanControllerSnapshot(
            phase: .scanned,
            selectedChoices: Set(DiskCleanChoice.allCases),
            scanResult: DiskCleanScanResult(
                choices: Set(DiskCleanChoice.allCases),
                candidates: [
                    DiskCleanCandidate(
                        id: "allowed",
                        ruleID: "rule",
                        choice: .cache,
                        title: "Cache",
                        path: "/Users/tester/Library/Caches/App",
                        sizeBytes: 10,
                        safety: .allowed,
                        risk: .low
                    ),
                    DiskCleanCandidate(
                        id: "protected",
                        ruleID: "rule",
                        choice: .cache,
                        title: "Cache",
                        path: "/Users/tester/Library/Keychains/login.keychain-db",
                        sizeBytes: 10,
                        safety: .protected(reason: "credentials"),
                        risk: .low
                    )
                ],
                scannedAt: Date(timeIntervalSince1970: 0)
            ),
            executionResult: nil,
            isResultStale: false,
            errorMessage: nil
        )

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.clean))

        XCTAssertEqual(controller.cleanSelectedCalls, [["allowed"]])
    }

    func testOpenDetailsActionUsesMenuBarStableActionID() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)
        let openDetails = try XCTUnwrap(
            controls.first { $0.id == DiskCleanPlugin.ControlID.openDetails }
        )

        XCTAssertEqual(DiskCleanPlugin.ControlID.openDetails, MenuBarContent.diskCleanOpenDetailsActionID)
        switch openDetails.actionBehavior {
        case .dismissBeforeHandling:
            break
        case .keepPresented:
            XCTFail("Open details action should dismiss the menu before opening the window")
        }
    }

    func testPluginHostIncludesDiskCleanWhenProvided() {
        let host = makePluginHostForTests(plugins: [DiskCleanPlugin(controller: FakeDiskCleanPluginController())])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "disk-clean" })
    }

    func testPluginHostExposesDiskCleanConfigurationWhenProvided() {
        let host = makePluginHostForTests(plugins: [DiskCleanPlugin(controller: DiskCleanController())])

        XCTAssertTrue(host.pluginConfigurationItems.contains { $0.id == "disk-clean" })
    }

    func testPresentPluginConfigurationRequestsDiskCleanSettings() {
        let host = makePluginHostForTests(plugins: [DiskCleanPlugin(controller: DiskCleanController())])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        host.presentPluginConfiguration(pluginID: "disk-clean")

        XCTAssertEqual(requests, [.settings(.pluginConfiguration("disk-clean"))])
    }
}

@MainActor
private final class FakeDiskCleanPluginController: DiskCleanControlling {
    var onStateChange: (() -> Void)?
    var snapshot = DiskCleanControllerSnapshot.initial
    private(set) var scanCallCount = 0
    private(set) var canceledOperationCount = 0
    private(set) var selectedChoiceChanges: [(choice: DiskCleanChoice, isSelected: Bool)] = []
    private(set) var cleanSelectedCalls: [Set<DiskCleanCandidate.ID>] = []

    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool) {
        selectedChoiceChanges.append((choice: choice, isSelected: isSelected))
        var nextChoices = snapshot.selectedChoices
        if isSelected {
            nextChoices.insert(choice)
        } else {
            nextChoices.remove(choice)
        }
        snapshot = DiskCleanControllerSnapshot(
            phase: snapshot.phase,
            selectedChoices: nextChoices,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            errorMessage: snapshot.errorMessage
        )
        onStateChange?()
    }

    func scan() {
        scanCallCount += 1
        onStateChange?()
    }

    func cleanSelected(candidateIDs: Set<DiskCleanCandidate.ID>) {
        cleanSelectedCalls.append(candidateIDs)
        onStateChange?()
    }

    func cancelCurrentOperation() {
        canceledOperationCount += 1
        onStateChange?()
    }
}
