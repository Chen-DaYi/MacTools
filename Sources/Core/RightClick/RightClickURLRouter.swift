import AppKit
import Foundation
import OSLog

@MainActor
final class RightClickURLRouter {
    static let shared = RightClickURLRouter()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "RightClickURLRouter"
    )
    private var fileActionService = RightClickFileActionService()
    private lazy var acceptedURLSchemes = Self.bundleURLSchemes()

    private init() {}

    func handle(_ urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    func handle(_ url: URL) {
        guard let scheme = url.scheme,
              acceptedURLSchemes.contains(scheme),
              url.host == "right-click" else {
            return
        }

        switch url.path {
        case "/new-folder":
            handleNewFolder(url)
        case "/new-file":
            handleNewFile(url)
        case "/open-terminal":
            handleOpenInTerminal(url)
        case "/open-with":
            handleOpenWith(url)
        default:
            logger.error("Unsupported right-click URL path: \(url.path, privacy: .public)")
        }
    }

    private func handleNewFolder(_ url: URL) {
        guard let directoryPath = queryValue("directory", in: url), !directoryPath.isEmpty else {
            logger.error("Missing directory for new-folder URL")
            return
        }

        do {
            let folderURL = try fileActionService.createFolder(in: URL(fileURLWithPath: directoryPath))
            logger.info("Created folder at \(folderURL.path, privacy: .public)")
        } catch {
            logger.error("Create folder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleNewFile(_ url: URL) {
        guard let directoryPath = queryValue("directory", in: url), !directoryPath.isEmpty,
              let ext = queryValue("ext", in: url) else {
            logger.error("Missing directory/ext for new-file URL")
            return
        }

        do {
            let fileURL = try fileActionService.createFile(
                in: URL(fileURLWithPath: directoryPath),
                extension: ext
            )
            logger.info("Created file at \(fileURL.path, privacy: .public)")
        } catch {
            logger.error("Create file failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleOpenInTerminal(_ url: URL) {
        guard let directoryPath = queryValue("directory", in: url), !directoryPath.isEmpty else {
            logger.error("Missing directory for open-terminal URL")
            return
        }
        let directory = URL(fileURLWithPath: directoryPath)
        guard RightClickTargetResolver.isDirectory(directory) else {
            logger.error("open-terminal directory unavailable: \(directoryPath, privacy: .public)")
            return
        }
        guard let terminalURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else {
            logger.error("Terminal app not found")
            return
        }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [logger] _, error in
            if let error {
                logger.error("open in terminal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleOpenWith(_ url: URL) {
        guard let request = Self.parseOpenWithRequest(url) else {
            logger.error("Invalid open-with URL")
            return
        }
        // Security: the URL scheme can be invoked by any process, so only open
        // with an app the user actually configured — not any .app on disk.
        let configuredApps = Set(RightClickConfigurationStore.load().openWithApps.map(\.appPath))
        guard configuredApps.contains(request.appURL.path) else {
            logger.error("open-with rejected: app not in configured list: \(request.appURL.path, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(
            request.files,
            withApplicationAt: request.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [logger] _, error in
            if let error {
                logger.error("open-with failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Parsed + validated open-with request, split out so the validation (app must
    /// be an existing `.app`, at least one file must exist) is unit-testable
    /// without launching anything. File-system probes are injected for tests.
    struct OpenWithRequest: Equatable {
        let appURL: URL
        let files: [URL]
    }

    nonisolated static func parseOpenWithRequest(
        _ url: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isApplicationBundle: (String) -> Bool = isApplicationBundleOnDisk
    ) -> OpenWithRequest? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let appPath = items.first(where: { $0.name == "app" })?.value,
              !appPath.isEmpty, isApplicationBundle(appPath) else {
            return nil
        }
        let files = items.filter { $0.name == "file" }
            .compactMap(\.value)
            .map { URL(fileURLWithPath: $0) }
            .filter { fileExists($0.path) }
        guard !files.isEmpty else { return nil }
        return OpenWithRequest(appURL: URL(fileURLWithPath: appPath), files: files)
    }

    nonisolated private static func isApplicationBundleOnDisk(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasSuffix(".app")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        queryValues(name, in: url).first
    }

    private func queryValues(_ name: String, in url: URL) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == name }
            .compactMap(\.value) ?? []
    }

    nonisolated static func bundleURLSchemes(bundle: Bundle = .main) -> Set<String> {
        guard let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return ["mactools"]
        }

        let schemes = urlTypes
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }

        return schemes.isEmpty ? ["mactools"] : Set(schemes)
    }
}
