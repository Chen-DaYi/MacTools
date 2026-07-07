import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, AppUpdating {
    @Published private(set) var canCheckForUpdates = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private var cancellables: Set<AnyCancellable> = []
    private var probeContinuation: CheckedContinuation<AppUpdateProbeResult, Never>?
    private var pendingProbeResult: AppUpdateProbeResult?

    override init() {
        super.init()

        let updater = updaterController.updater
        updater.clearFeedURLFromUserDefaults()
        canCheckForUpdates = updater.canCheckForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
            .store(in: &cancellables)
    }

    func installationEligibility() -> UpdateInstallationEligibility {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let path = bundleURL.path

        if path.contains("/AppTranslocation/") {
            return .blocked(AppL10n.settings(
                "about.update.error.quarantineLocation",
                defaultValue: "请先将应用移到 Applications 再更新。当前应用仍在系统隔离位置中运行。"
            ))
        }

        if path.hasPrefix("/Volumes/") || path.contains("/Volumes/") {
            return .blocked(AppL10n.settings(
                "about.update.error.diskImageLocation",
                defaultValue: "请先将应用移到 Applications 再更新。当前应用仍在磁盘镜像中运行。"
            ))
        }

        do {
            let resourceValues = try bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            if resourceValues.volumeIsReadOnly == true {
                return .blocked(AppL10n.settings(
                    "about.update.error.readOnlyVolume",
                    defaultValue: "请先将应用移到 Applications 再更新。当前应用所在磁盘是只读的。"
                ))
            }
        } catch {
            return .blocked(AppL10n.settings(
                "about.update.error.unwritableLocationUnknown",
                defaultValue: "无法确认当前安装位置是否可写，请将应用移到 Applications 后再更新。"
            ))
        }

        return .allowed
    }

    func checkForUpdateInformation() async -> AppUpdateProbeResult {
        guard canCheckForUpdates else {
            return .error(message: AppL10n.settings("about.update.error.servicePreparing", defaultValue: "更新服务正在准备中，请稍后再试。"))
        }

        guard probeContinuation == nil else {
            return .error(message: AppL10n.settings("about.update.error.alreadyChecking", defaultValue: "正在检查更新，请稍后再试。"))
        }

        return await withCheckedContinuation { continuation in
            pendingProbeResult = nil
            probeContinuation = continuation
            updaterController.updater.checkForUpdateInformation()
        }
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    private func finishProbe(with result: AppUpdateProbeResult) {
        guard let probeContinuation else {
            return
        }

        self.probeContinuation = nil
        pendingProbeResult = nil
        probeContinuation.resume(returning: result)
    }

    /// Sparkle reports "no update found" to its delegate as `SUNoUpdateError` (code 1001).
    /// Treat it as "already up to date" rather than a real failure.
    private func isNoUpdateError(_ error: Error) -> Bool {
        (error as NSError).code == 1001
    }

    private func simplifiedErrorMessage(from error: Error) -> String {
        let nsError = error as NSError

        if let failureReason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
           !failureReason.isEmpty {
            return failureReason
        }

        return nsError.localizedDescription
    }
}

@MainActor
extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard probeContinuation != nil else {
            return
        }

        pendingProbeResult = .updateAvailable(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard probeContinuation != nil else {
            return
        }

        pendingProbeResult = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard probeContinuation != nil else {
            return
        }

        // SUNoUpdateError (code 1001) means no update was found — not a real failure.
        // It will be properly resolved in didFinishUpdateCycleFor.
        if isNoUpdateError(error) { return }

        finishProbe(with: .error(message: simplifiedErrorMessage(from: error)))
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard probeContinuation != nil else {
            return
        }

        if let error, !isNoUpdateError(error) {
            finishProbe(with: .error(message: simplifiedErrorMessage(from: error)))
            return
        }

        finishProbe(with: pendingProbeResult ?? .upToDate)
    }
}
