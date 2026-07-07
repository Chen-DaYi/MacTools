import XCTest
@testable import MacTools

@MainActor
final class AboutUpdateViewModelTests: XCTestCase {
    func testProbeTransitionsToUpToDateState() async {
        let updater = StubUpdater()
        updater.probeResult = .upToDate

        let viewModel = AboutUpdateViewModel(updater: updater)
        await viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.state, .upToDate)
        XCTAssertEqual(
            viewModel.primaryButtonTitle,
            AppL10n.settings("about.update.check", defaultValue: "检查更新")
        )
    }

    func testProbeTransitionsToUpdateAvailableState() async {
        let updater = StubUpdater()
        updater.probeResult = .updateAvailable(version: "0.3.0")

        let viewModel = AboutUpdateViewModel(updater: updater)
        await viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.state, .updateAvailable(version: "0.3.0"))
        XCTAssertEqual(
            viewModel.primaryButtonTitle,
            AppL10n.settings("about.update.installNow", defaultValue: "立即更新")
        )
    }

    func testBlockedInstallPreservesImmediateUpdateAction() async {
        let updater = StubUpdater()
        updater.probeResult = .updateAvailable(version: "0.3.0")
        updater.eligibility = .blocked("请先将应用移到 Applications 再更新。")

        let viewModel = AboutUpdateViewModel(updater: updater)
        await viewModel.performPrimaryAction()
        await viewModel.performPrimaryAction()

        XCTAssertEqual(
            viewModel.state,
            .blocked(reason: "请先将应用移到 Applications 再更新。")
        )
        XCTAssertEqual(
            viewModel.primaryButtonTitle,
            AppL10n.settings("about.update.installNow", defaultValue: "立即更新")
        )
        XCTAssertEqual(updater.checkForUpdatesCallCount, 0)
    }

    func testVersionDescriptionFormatting() {
        XCTAssertEqual(
            AppMetadata.formattedVersionDescription(shortVersion: "1.2.3", buildNumber: "45"),
            "1.2.3 (45)"
        )
    }
}

@MainActor
private final class StubUpdater: AppUpdating {
    var canCheckForUpdates = true
    var eligibility = UpdateInstallationEligibility.allowed
    var probeResult: AppUpdateProbeResult = .upToDate
    private(set) var checkForUpdatesCallCount = 0

    func installationEligibility() -> UpdateInstallationEligibility {
        eligibility
    }

    func checkForUpdateInformation() async -> AppUpdateProbeResult {
        probeResult
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}
