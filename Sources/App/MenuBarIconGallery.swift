import AppKit
import Foundation
import SwiftUI

struct MenuBarIconGalleryCategory: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
}

struct MenuBarIconGalleryAsset: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let categoryID: String
    let version: String
    let previewPath: String?
    let framePaths: [String]?
    let framePathPattern: String?
    let archivePath: String?
    let archiveFramePathPattern: String?
    let frameCount: Int
    let frameDuration: TimeInterval
}

struct MenuBarIconGalleryCatalog: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date?
    let baseURL: URL?
    let categories: [MenuBarIconGalleryCategory]
    let assets: [MenuBarIconGalleryAsset]
}

struct MenuBarIconRemoteAssetSelection: Codable, Equatable, Hashable {
    let id: String
    let version: String
    let displayName: String
    let frameFileNames: [String]
    let frameDuration: TimeInterval
}

enum MenuBarIconRemoteAssetReference {
    static let fileNamePrefix = "remote-asset:"

    static func fileName(assetID: String, version: String) -> String {
        "\(fileNamePrefix)\(assetID)#\(version)"
    }

    static func parse(_ fileName: String) -> (assetID: String, version: String)? {
        guard fileName.hasPrefix(fileNamePrefix) else {
            return nil
        }

        let value = fileName.dropFirst(fileNamePrefix.count)
        let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }

        return (assetID: parts[0], version: parts[1])
    }
}

enum MenuBarIconGalleryStatus: Equatable {
    case idle
    case loading
    case loaded(Date)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }

        return false
    }
}

enum MenuBarIconGalleryAssetState: Equatable {
    case available
    case downloading
    case cached
    case failed(String)
}

enum MenuBarIconGallerySource: Equatable {
    case production(URL)
    case localDevelopment(URL)

    var url: URL {
        switch self {
        case let .production(url), let .localDevelopment(url):
            return url
        }
    }

    var allowsFileResources: Bool {
        switch self {
        case .production:
            return false
        case .localDevelopment:
            return true
        }
    }
}

struct MenuBarIconGalleryProviderConfiguration {
    static let productionCatalogURL = URL(string: "https://mactools.ggbond.app/icon-gallery/catalog.json")!

    static func defaultSource(environment: [String: String] = ProcessInfo.processInfo.environment) -> MenuBarIconGallerySource {
        #if DEBUG
        if let rawURL = environment["MACTOOLS_ICON_CATALOG_URL"],
           let url = URL(string: rawURL) {
            return source(for: url)
        }

        if FileManager.default.fileExists(atPath: defaultLocalDevelopmentCatalogURL.path) {
            return .localDevelopment(defaultLocalDevelopmentCatalogURL)
        }
        #endif

        return .production(productionCatalogURL)
    }

    private static func source(for url: URL) -> MenuBarIconGallerySource {
        if url.isFileURL {
            return .localDevelopment(url)
        }

        return .production(url)
    }

    static var defaultLocalDevelopmentCatalogURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("LocalIconGallery", isDirectory: true)
            .appendingPathComponent("catalog.dev.json", isDirectory: false)
    }
}

struct MenuBarIconGallerySnapshot: Equatable {
    let catalog: MenuBarIconGalleryCatalog
    let catalogURL: URL
    let contentBaseURL: URL
    let allowsFileResources: Bool
    let loadedAt: Date
}

@MainActor
protocol MenuBarIconGalleryProviding {
    func loadCatalog() async throws -> MenuBarIconGallerySnapshot
}

struct MenuBarIconGalleryProvider: MenuBarIconGalleryProviding {
    private let source: MenuBarIconGallerySource
    private let session: URLSession
    private let now: () -> Date

    init(
        source: MenuBarIconGallerySource = MenuBarIconGalleryProviderConfiguration.defaultSource(),
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.session = session
        self.now = now
    }

    func loadCatalog() async throws -> MenuBarIconGallerySnapshot {
        let data: Data
        let catalogURL = source.url

        if catalogURL.isFileURL {
            data = try Data(contentsOf: catalogURL)
        } else {
            var request = URLRequest(url: catalogURL)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadRevalidatingCacheData
            let (responseData, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw MenuBarIconGalleryError.httpStatus(httpResponse.statusCode)
            }

            data = responseData
        }

        let catalog = try MenuBarIconGalleryCoding.decoder.decode(MenuBarIconGalleryCatalog.self, from: data)
        try MenuBarIconGalleryValidator.validate(catalog)

        let contentBaseURL = catalog.baseURL ?? catalogURL.deletingLastPathComponent().appendingPathComponent("", isDirectory: true)
        return MenuBarIconGallerySnapshot(
            catalog: catalog,
            catalogURL: catalogURL,
            contentBaseURL: contentBaseURL,
            allowsFileResources: source.allowsFileResources,
            loadedAt: now()
        )
    }
}

enum MenuBarIconGalleryCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum MenuBarIconGalleryValidator {
    static let maximumFrameCount = 120

    static func validate(_ catalog: MenuBarIconGalleryCatalog) throws {
        guard catalog.schemaVersion == 1 else {
            throw MenuBarIconGalleryError.unsupportedSchemaVersion(catalog.schemaVersion)
        }

        var categoryIDs = Set<String>()
        for category in catalog.categories {
            guard !category.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !category.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MenuBarIconGalleryError.invalidCatalog
            }
            guard categoryIDs.insert(category.id).inserted else {
                throw MenuBarIconGalleryError.invalidCatalog
            }
        }

        var assetIDs = Set<String>()
        for asset in catalog.assets {
            guard assetIDs.insert(asset.id).inserted else {
                throw MenuBarIconGalleryError.invalidCatalog
            }
            guard categoryIDs.contains(asset.categoryID),
                  !asset.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !asset.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...maximumFrameCount).contains(asset.frameCount),
                  asset.frameDuration > 0
            else {
                throw MenuBarIconGalleryError.invalidCatalog
            }
            guard asset.archivePath != nil || asset.framePaths != nil || asset.framePathPattern != nil else {
                throw MenuBarIconGalleryError.invalidCatalog
            }
        }
    }
}

@MainActor
struct MenuBarIconRemoteAssetStore {
    static let maximumFrameFileSize = 1 * 1024 * 1024
    static let maximumArchiveFileSize = 25 * 1024 * 1024
    static let maximumDecodedPixelArea = 512 * 512

    let rootDirectory: URL
    let fileManager: FileManager
    let session: URLSession

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.session = session
    }

    func isAssetCached(_ asset: MenuBarIconGalleryAsset) -> Bool {
        let frameNames = expectedFrameFileNames(frameCount: asset.frameCount)
        return frameNames.allSatisfy { frameName in
            fileManager.fileExists(atPath: framesDirectory(assetID: asset.id, version: asset.version).appendingPathComponent(frameName).path)
        }
    }

    func installAsset(
        _ asset: MenuBarIconGalleryAsset,
        contentBaseURL: URL,
        allowsFileResources: Bool
    ) async throws -> MenuBarIconRemoteAssetSelection {
        let stagingDirectory = rootDirectory
            .appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("\(safePathComponent(asset.id))-\(safePathComponent(asset.version))-\(UUID().uuidString)", isDirectory: true)
        let stagingFramesDirectory = stagingDirectory.appendingPathComponent("frames", isDirectory: true)
        let destinationDirectory = assetDirectory(assetID: asset.id, version: asset.version)
        let destinationFramesDirectory = destinationDirectory.appendingPathComponent("frames", isDirectory: true)

        try fileManager.createDirectory(at: stagingFramesDirectory, withIntermediateDirectories: true)

        do {
            if let archivePath = asset.archivePath {
                try await installArchive(
                    archivePath: archivePath,
                    asset: asset,
                    contentBaseURL: contentBaseURL,
                    allowsFileResources: allowsFileResources,
                    stagingFramesDirectory: stagingFramesDirectory,
                    stagingDirectory: stagingDirectory
                )
            } else {
                try await installIndividualFrames(
                    asset: asset,
                    contentBaseURL: contentBaseURL,
                    allowsFileResources: allowsFileResources,
                    stagingFramesDirectory: stagingFramesDirectory
                )
            }

            try validateFrames(in: stagingFramesDirectory, frameCount: asset.frameCount)
            try replaceDirectory(at: destinationDirectory, with: stagingFramesDirectory, destinationFramesDirectory: destinationFramesDirectory)
            try removeEmptyStagingIfNeeded(stagingDirectory)

            return MenuBarIconRemoteAssetSelection(
                id: asset.id,
                version: asset.version,
                displayName: asset.title,
                frameFileNames: expectedFrameFileNames(frameCount: asset.frameCount),
                frameDuration: asset.frameDuration
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func pruneRemoteAssets(keeping selection: MenuBarIconRemoteAssetSelection?) {
        guard let selection else {
            try? fileManager.removeItem(at: rootDirectory)
            return
        }

        let keepPath = assetDirectory(assetID: selection.id, version: selection.version).standardizedFileURL.path
        let protectedNames = Set(["Staging", safePathComponent(selection.id)])

        guard let assetDirectories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for assetDirectory in assetDirectories {
            guard assetDirectory.lastPathComponent != "Staging" else {
                try? fileManager.removeItem(at: assetDirectory)
                continue
            }
            guard !protectedNames.contains(assetDirectory.lastPathComponent) else {
                continue
            }
            try? fileManager.removeItem(at: assetDirectory)
        }

        let selectedAssetRoot = rootDirectory.appendingPathComponent(safePathComponent(selection.id), isDirectory: true)
        guard let versionDirectories = try? fileManager.contentsOfDirectory(
            at: selectedAssetRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for versionDirectory in versionDirectories where versionDirectory.standardizedFileURL.path != keepPath {
            try? fileManager.removeItem(at: versionDirectory)
        }
    }

    func frameURLs(for selection: MenuBarIconRemoteAssetSelection) -> [URL] {
        let directory = framesDirectory(assetID: selection.id, version: selection.version)
        return selection.frameFileNames.map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    func hasFrames(for selection: MenuBarIconRemoteAssetSelection) -> Bool {
        frameURLs(for: selection).allSatisfy { fileManager.fileExists(atPath: $0.path) }
    }

    func loadPreviewImage(
        for asset: MenuBarIconGalleryAsset,
        contentBaseURL: URL,
        allowsFileResources: Bool
    ) async throws -> NSImage {
        let path = asset.previewPath ?? asset.framePaths?.first ?? resolvedFramePath(pattern: asset.framePathPattern, index: 0)
        guard let path else {
            throw MenuBarIconGalleryError.invalidAsset(asset.id)
        }

        let url = try resolvedResourceURL(path: path, contentBaseURL: contentBaseURL, allowsFileResources: allowsFileResources)
        let data = try await data(from: url)
        guard data.count <= Self.maximumFrameFileSize,
              let image = NSImage(data: data),
              isDecodedImageSizeAcceptable(image)
        else {
            throw MenuBarIconGalleryError.invalidFrame(asset.id)
        }

        return image
    }

    func framesDirectory(assetID: String, version: String) -> URL {
        assetDirectory(assetID: assetID, version: version)
            .appendingPathComponent("frames", isDirectory: true)
    }

    private func assetDirectory(assetID: String, version: String) -> URL {
        rootDirectory
            .appendingPathComponent(safePathComponent(assetID), isDirectory: true)
            .appendingPathComponent(safePathComponent(version), isDirectory: true)
    }

    private func installArchive(
        archivePath: String,
        asset: MenuBarIconGalleryAsset,
        contentBaseURL: URL,
        allowsFileResources: Bool,
        stagingFramesDirectory: URL,
        stagingDirectory: URL
    ) async throws {
        let archiveURL = try resolvedResourceURL(
            path: archivePath,
            contentBaseURL: contentBaseURL,
            allowsFileResources: allowsFileResources
        )
        let archiveFileURL = try await materializeResource(
            archiveURL,
            fileName: "asset.zip",
            in: stagingDirectory,
            maximumSize: Self.maximumArchiveFileSize
        )
        let extractionDirectory = stagingDirectory.appendingPathComponent("Expanded", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        try await MenuBarIconGalleryArchiveExtractor.extract(zipURL: archiveFileURL, destinationURL: extractionDirectory)

        let pattern = asset.archiveFramePathPattern ?? "frames/frame-%03d.png"
        for index in 0..<asset.frameCount {
            guard let relativePath = resolvedFramePath(pattern: pattern, index: index) else {
                throw MenuBarIconGalleryError.invalidAsset(asset.id)
            }
            let sourceURL = extractionDirectory.appendingPathComponent(relativePath, isDirectory: false)
            try copyFrame(
                from: sourceURL,
                to: stagingFramesDirectory.appendingPathComponent(frameFileName(index: index), isDirectory: false),
                allowedRoot: extractionDirectory
            )
        }
    }

    private func installIndividualFrames(
        asset: MenuBarIconGalleryAsset,
        contentBaseURL: URL,
        allowsFileResources: Bool,
        stagingFramesDirectory: URL
    ) async throws {
        let framePaths = try resolvedFramePaths(for: asset)
        guard framePaths.count == asset.frameCount else {
            throw MenuBarIconGalleryError.invalidAsset(asset.id)
        }

        for (index, framePath) in framePaths.enumerated() {
            let sourceURL = try resolvedResourceURL(
                path: framePath,
                contentBaseURL: contentBaseURL,
                allowsFileResources: allowsFileResources
            )
            let destinationURL = stagingFramesDirectory.appendingPathComponent(frameFileName(index: index), isDirectory: false)

            if sourceURL.isFileURL {
                try copyFrame(from: sourceURL, to: destinationURL, allowedRoot: nil)
            } else {
                let temporaryURL = try await materializeResource(
                    sourceURL,
                    fileName: "download-\(frameFileName(index: index))",
                    in: stagingFramesDirectory.deletingLastPathComponent(),
                    maximumSize: Self.maximumFrameFileSize
                )
                try copyFrame(from: temporaryURL, to: destinationURL, allowedRoot: nil)
            }
        }
    }

    private func resolvedFramePaths(for asset: MenuBarIconGalleryAsset) throws -> [String] {
        if let framePaths = asset.framePaths {
            return framePaths
        }

        guard let framePathPattern = asset.framePathPattern else {
            throw MenuBarIconGalleryError.invalidAsset(asset.id)
        }

        return try (0..<asset.frameCount).map { index in
            guard let path = resolvedFramePath(pattern: framePathPattern, index: index) else {
                throw MenuBarIconGalleryError.invalidAsset(asset.id)
            }
            return path
        }
    }

    private func resolvedFramePath(pattern: String?, index: Int) -> String? {
        guard let pattern else {
            return nil
        }

        if pattern.contains("%03d") {
            return pattern.replacingOccurrences(of: "%03d", with: String(format: "%03d", index))
        }

        if pattern.contains("%d") {
            return pattern.replacingOccurrences(of: "%d", with: "\(index)")
        }

        return index == 0 ? pattern : nil
    }

    private func resolvedResourceURL(
        path: String,
        contentBaseURL: URL,
        allowsFileResources: Bool
    ) throws -> URL {
        guard let url = URL(string: path, relativeTo: contentBaseURL)?.absoluteURL else {
            throw MenuBarIconGalleryError.invalidResourceURL(path)
        }

        if url.isFileURL {
            guard allowsFileResources else {
                throw MenuBarIconGalleryError.invalidResourceURL(path)
            }
            return url.standardizedFileURL
        }

        guard url.scheme?.lowercased() == "https" else {
            throw MenuBarIconGalleryError.invalidResourceURL(path)
        }
        guard url.absoluteString.hasPrefix(contentBaseURL.absoluteURL.absoluteString) else {
            throw MenuBarIconGalleryError.invalidResourceURL(path)
        }

        return url
    }

    private func materializeResource(
        _ url: URL,
        fileName: String,
        in directory: URL,
        maximumSize: Int
    ) async throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = directory.appendingPathComponent(fileName, isDirectory: false)

        if url.isFileURL {
            try copyFrame(from: url, to: destinationURL, allowedRoot: nil, maximumSize: maximumSize)
            return destinationURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporaryURL, response) = try await session.download(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw MenuBarIconGalleryError.httpStatus(httpResponse.statusCode)
        }

        let fileSize = try fileSize(at: temporaryURL)
        guard fileSize <= maximumSize else {
            throw MenuBarIconGalleryError.resourceTooLarge(fileSize)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func data(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw MenuBarIconGalleryError.httpStatus(httpResponse.statusCode)
        }

        return data
    }

    private func copyFrame(
        from sourceURL: URL,
        to destinationURL: URL,
        allowedRoot: URL?,
        maximumSize: Int = maximumFrameFileSize
    ) throws {
        if let allowedRoot {
            let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
            let rootPath = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path
            guard sourcePath.hasPrefix(rootPath + "/") else {
                throw MenuBarIconGalleryError.archiveEscapedDestination
            }
        }

        let fileSize = try fileSize(at: sourceURL)
        guard fileSize <= maximumSize else {
            throw MenuBarIconGalleryError.resourceTooLarge(fileSize)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func validateFrames(in directory: URL, frameCount: Int) throws {
        for index in 0..<frameCount {
            let frameURL = directory.appendingPathComponent(frameFileName(index: index), isDirectory: false)
            guard let image = NSImage(contentsOf: frameURL),
                  isDecodedImageSizeAcceptable(image)
            else {
                throw MenuBarIconGalleryError.invalidFrame(frameURL.lastPathComponent)
            }
        }
    }

    private func isDecodedImageSizeAcceptable(_ image: NSImage) -> Bool {
        guard let cgImage = cgImage(from: image) else {
            return false
        }

        return cgImage.width * cgImage.height <= Self.maximumDecodedPixelArea
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private func replaceDirectory(
        at destinationDirectory: URL,
        with stagingFramesDirectory: URL,
        destinationFramesDirectory: URL
    ) throws {
        let parentDirectory = destinationDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationDirectory.path) {
            try fileManager.removeItem(at: destinationDirectory)
        }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: stagingFramesDirectory, to: destinationFramesDirectory)
    }

    private func removeEmptyStagingIfNeeded(_ stagingDirectory: URL) throws {
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
    }

    private func fileSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize {
            return fileSize
        }

        return try Data(contentsOf: url).count
    }

    private func expectedFrameFileNames(frameCount: Int) -> [String] {
        (0..<frameCount).map(frameFileName(index:))
    }

    private func frameFileName(index: Int) -> String {
        String(format: "frame-%03d.png", index)
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "asset" : result
    }
}

@MainActor
final class MenuBarIconGalleryLibrary: ObservableObject {
    @Published private(set) var status: MenuBarIconGalleryStatus = .idle
    @Published private(set) var categories: [MenuBarIconGalleryCategory] = []
    @Published private(set) var assets: [MenuBarIconGalleryAsset] = []
    @Published private(set) var assetStates: [String: MenuBarIconGalleryAssetState] = [:]
    @Published private(set) var previewImages: [String: NSImage] = [:]
    @Published private(set) var lastErrorMessage: String?

    private let provider: any MenuBarIconGalleryProviding
    private let store: MenuBarIconRemoteAssetStore
    private var snapshot: MenuBarIconGallerySnapshot?
    private var didAttemptInitialLoad = false

    init(
        provider: any MenuBarIconGalleryProviding = MenuBarIconGalleryProvider(),
        store: MenuBarIconRemoteAssetStore? = nil,
        rootDirectory: URL? = nil
    ) {
        self.provider = provider
        let root = rootDirectory ?? AppStorageScope.applicationSupportRoot()
            .appendingPathComponent("MenuBarIcons", isDirectory: true)
            .appendingPathComponent("RemoteAssets", isDirectory: true)
        self.store = store ?? MenuBarIconRemoteAssetStore(rootDirectory: root)
    }

    func loadCatalogIfNeeded() async {
        guard !didAttemptInitialLoad else {
            return
        }

        didAttemptInitialLoad = true
        await refreshCatalog()
    }

    func refreshCatalog() async {
        status = .loading
        lastErrorMessage = nil

        do {
            let snapshot = try await provider.loadCatalog()
            self.snapshot = snapshot
            categories = snapshot.catalog.categories
            assets = snapshot.catalog.assets
            assetStates = Dictionary(
                uniqueKeysWithValues: snapshot.catalog.assets.map { asset in
                    (asset.id, store.isAssetCached(asset) ? .cached : .available)
                }
            )
            status = .loaded(snapshot.loadedAt)
        } catch {
            lastErrorMessage = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    func state(for asset: MenuBarIconGalleryAsset) -> MenuBarIconGalleryAssetState {
        assetStates[asset.id] ?? (store.isAssetCached(asset) ? .cached : .available)
    }

    func previewImage(for asset: MenuBarIconGalleryAsset) -> NSImage? {
        previewImages[asset.id]
    }

    func loadPreviewIfNeeded(for asset: MenuBarIconGalleryAsset) async {
        guard previewImages[asset.id] == nil, let snapshot else {
            return
        }

        do {
            previewImages[asset.id] = try await store.loadPreviewImage(
                for: asset,
                contentBaseURL: snapshot.contentBaseURL,
                allowsFileResources: snapshot.allowsFileResources
            )
        } catch {
            previewImages[asset.id] = nil
        }
    }

    func selectRecentItem(_ item: MenuBarIconRecentItem, iconSettings: MenuBarIconSettings) async -> Bool {
        guard let selection = iconSettings.remoteAssetSelection(forRecentItem: item) else {
            iconSettings.useRecentIcon(item)
            return iconSettings.lastErrorMessage == nil
        }

        if iconSettings.isRemoteAssetCached(for: item) {
            iconSettings.useRecentIcon(item)
            return iconSettings.lastErrorMessage == nil
        }

        await loadCatalogIfNeeded()
        if snapshot == nil {
            await refreshCatalog()
        }

        guard let asset = assets.first(where: { asset in
            asset.id == selection.id && asset.version == selection.version
        }) else {
            iconSettings.reportError(lastErrorMessage ?? AppL10n.settings(
                "menuBarIcon.gallery.error.recentAssetMissing",
                defaultValue: "最近使用的在线图标已不在图库中。"
            ))
            return false
        }

        let didSelect = await selectAsset(asset, iconSettings: iconSettings)
        if !didSelect, let lastErrorMessage {
            iconSettings.reportError(lastErrorMessage)
        }
        return didSelect
    }

    func selectAsset(_ asset: MenuBarIconGalleryAsset, iconSettings: MenuBarIconSettings) async -> Bool {
        guard let snapshot else {
            lastErrorMessage = AppL10n.settings("menuBarIcon.gallery.error.notLoaded", defaultValue: "图标图库尚未加载。")
            return false
        }

        assetStates[asset.id] = .downloading
        lastErrorMessage = nil

        do {
            let selection = try await store.installAsset(
                asset,
                contentBaseURL: snapshot.contentBaseURL,
                allowsFileResources: snapshot.allowsFileResources
            )
            iconSettings.useRemoteAsset(selection)
            store.pruneRemoteAssets(keeping: selection)
            assetStates = Dictionary(
                uniqueKeysWithValues: assets.map { item in
                    (item.id, item.id == asset.id ? .cached : .available)
                }
            )
            return true
        } catch {
            let message = error.localizedDescription
            assetStates[asset.id] = .failed(message)
            lastErrorMessage = message
            return false
        }
    }
}

enum MenuBarIconGalleryError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidCatalog
    case invalidAsset(String)
    case invalidResourceURL(String)
    case httpStatus(Int)
    case resourceTooLarge(Int)
    case invalidFrame(String)
    case archiveEscapedDestination
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return AppL10n.settingsFormat("menuBarIcon.gallery.error.unsupportedSchemaFormat", defaultValue: "图标图库版本不支持：%d", version)
        case .invalidCatalog:
            return AppL10n.settings("menuBarIcon.gallery.error.invalidCatalog", defaultValue: "图标图库格式无效。")
        case let .invalidAsset(id):
            return AppL10n.settingsFormat("menuBarIcon.gallery.error.invalidAssetFormat", defaultValue: "图标素材无效：%@", id)
        case let .invalidResourceURL(path):
            return AppL10n.settingsFormat("menuBarIcon.gallery.error.invalidResourceURLFormat", defaultValue: "图标资源地址无效：%@", path)
        case let .httpStatus(statusCode):
            return AppL10n.settingsFormat("menuBarIcon.gallery.error.httpStatusFormat", defaultValue: "图标资源下载失败：HTTP %d", statusCode)
        case let .resourceTooLarge(size):
            return AppL10n.settingsFormat("menuBarIcon.gallery.error.resourceTooLargeFormat", defaultValue: "图标资源过大：%d", size)
        case let .invalidFrame(name):
            return AppL10n.settingsFormat("menuBarIcon.gallery.error.invalidFrameFormat", defaultValue: "图标帧无法读取：%@", name)
        case .archiveEscapedDestination:
            return AppL10n.settings("menuBarIcon.gallery.error.unsafeArchivePath", defaultValue: "图标压缩包包含不安全路径。")
        case let .unzipFailed(reason):
            return AppL10n.settingsFormat("menuBarIcon.gallery.error.unzipFailedFormat", defaultValue: "图标压缩包解压失败：%@", reason)
        }
    }
}

private enum MenuBarIconGalleryArchiveExtractor {
    static func extract(zipURL: URL, destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-x",
                "-k",
                "--sequesterRsrc",
                "--rsrc",
                zipURL.path,
                destinationURL.path
            ]

            let pipe = Pipe()
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "ditto \(process.terminationStatus)"
                throw MenuBarIconGalleryError.unzipFailed(message)
            }
        }.value
    }
}
