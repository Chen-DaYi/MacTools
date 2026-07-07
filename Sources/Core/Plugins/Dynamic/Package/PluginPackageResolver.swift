import CryptoKit
import Foundation

@MainActor
protocol PluginPackageResolving {
    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL
}

@MainActor
final class PluginPackageResolver: PluginPackageResolving {
    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private let session: URLSession
    private let maximumPackageSize: Int64

    init(
        temporaryDirectory: URL,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        maximumPackageSize: Int64 = 200 * 1024 * 1024
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
        self.session = session
        self.maximumPackageSize = maximumPackageSize
    }

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let workingDirectory = temporaryDirectory
            .appendingPathComponent("\(entry.id)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        do {
            let downloadedURL = try await materializePackage(entry.package, in: workingDirectory)
            try validatePackageFile(downloadedURL, expected: entry.package)
            let packageURL = try await expandedPackageURL(from: downloadedURL, in: workingDirectory)
            try validateResolvedPackage(packageURL, matches: entry)
            return packageURL
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    private func materializePackage(
        _ package: PluginCatalogPackage,
        in workingDirectory: URL
    ) async throws -> URL {
        if package.url.isFileURL {
            return try copyLocalPackage(package.url, to: workingDirectory)
        }

        guard package.url.scheme?.lowercased() == "https" else {
            throw PluginPackageResolverError.unsupportedPackageURL(package.url)
        }

        return try await downloadPackage(package.url, to: workingDirectory)
    }

    private func copyLocalPackage(_ sourceURL: URL, to workingDirectory: URL) throws -> URL {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PluginPackageResolverError.missingLocalPackage(sourceURL)
        }

        let destinationURL = workingDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func downloadPackage(_ url: URL, to workingDirectory: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (temporaryURL, response) = try await session.download(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw PluginPackageResolverError.httpStatus(httpResponse.statusCode)
        }

        let fileName = response.suggestedFilename ?? url.lastPathComponent
        let destinationURL = workingDirectory.appendingPathComponent(fileName.isEmpty ? "Package" : fileName)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func validatePackageFile(_ url: URL, expected package: PluginCatalogPackage) throws {
        let metrics = try packageMetrics(for: url)

        guard metrics.size == package.size else {
            throw PluginPackageResolverError.packageSizeMismatch(expected: package.size, actual: metrics.size)
        }

        guard metrics.size <= maximumPackageSize else {
            throw PluginPackageResolverError.packageTooLarge(metrics.size)
        }

        guard metrics.sha256.caseInsensitiveCompare(package.sha256) == .orderedSame else {
            throw PluginPackageResolverError.checksumMismatch(expected: package.sha256, actual: metrics.sha256)
        }
    }

    private func expandedPackageURL(from url: URL, in workingDirectory: URL) async throws -> URL {
        if url.pathExtension == "mactoolsplugin" {
            return url
        }

        if url.pathExtension == "zip" {
            return try await extractZipPackage(url, in: workingDirectory)
        }

        throw PluginPackageResolverError.unsupportedPackageFormat(url)
    }

    private func extractZipPackage(_ url: URL, in workingDirectory: URL) async throws -> URL {
        let extractionDirectory = workingDirectory.appendingPathComponent("Expanded", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

        try await PluginZipExtractor.extract(zipURL: url, destinationURL: extractionDirectory)

        let packageURLs = try fileManager.contentsOfDirectory(
            at: extractionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "mactoolsplugin" }

        guard packageURLs.count == 1, let packageURL = packageURLs.first else {
            throw PluginPackageResolverError.invalidExpandedPackage
        }

        let resolvedPackagePath = packageURL.resolvingSymlinksInPath().path
        let resolvedExtractionPath = extractionDirectory.resolvingSymlinksInPath().path

        guard resolvedPackagePath.hasPrefix(resolvedExtractionPath + "/") else {
            throw PluginPackageResolverError.archiveEscapedDestination
        }

        return packageURL
    }

    private func validateResolvedPackage(_ packageURL: URL, matches entry: PluginCatalogEntry) throws {
        let manifest = try PluginPackageManifestLoader.load(from: packageURL)

        guard manifest.id == entry.id else {
            throw PluginPackageResolverError.manifestMismatch(field: "id")
        }

        guard manifest.version == entry.version else {
            throw PluginPackageResolverError.manifestMismatch(field: "version")
        }

        guard manifest.pluginKitVersion == entry.pluginKitVersion else {
            throw PluginPackageResolverError.manifestMismatch(field: "pluginKitVersion")
        }

        guard manifest.minHostVersion == entry.minimumHostVersion else {
            throw PluginPackageResolverError.manifestMismatch(field: "minimumHostVersion")
        }

        guard manifest.releaseChannel == entry.releaseChannel else {
            throw PluginPackageResolverError.manifestMismatch(field: "releaseChannel")
        }
    }

    static func packageMetrics(for url: URL, fileManager: FileManager = .default) throws -> PluginPackageMetrics {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])

        if values.isDirectory == true {
            return try directoryMetrics(for: url, fileManager: fileManager)
        }

        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return PluginPackageMetrics(
            size: Int64(data.count),
            sha256: digest.map { String(format: "%02x", $0) }.joined()
        )
    }

    private func packageMetrics(for url: URL) throws -> PluginPackageMetrics {
        try Self.packageMetrics(for: url, fileManager: fileManager)
    }

    private static func directoryMetrics(
        for url: URL,
        fileManager: FileManager
    ) throws -> PluginPackageMetrics {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PluginPackageResolverError.unsupportedPackageFormat(url)
        }

        var hasher = SHA256()
        var size: Int64 = 0
        let basePath = url.standardizedFileURL.path
        let files = try enumerator.compactMap { item -> (url: URL, relativePath: String, fileSize: Int?)? in
            guard let fileURL = item as? URL else {
                return nil
            }

            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                return nil
            }

            let standardizedPath = fileURL.standardizedFileURL.path
            let relativePath = String(
                standardizedPath
                    .dropFirst(basePath.count)
                    .drop { $0 == "/" }
            )
            return (fileURL, relativePath, values.fileSize)
        }
        .sorted { lhs, rhs in
            lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }

        for file in files {
            let fileData = try Data(contentsOf: file.url)
            let relativePath = file.relativePath
            let pathData = Data(relativePath.utf8)
            hasher.update(data: pathData)
            hasher.update(data: Data([0]))
            hasher.update(data: fileData)
            hasher.update(data: Data([0]))
            size += Int64(file.fileSize ?? fileData.count)
        }

        let digest = hasher.finalize()
        return PluginPackageMetrics(
            size: size,
            sha256: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

struct PluginPackageMetrics: Equatable {
    let size: Int64
    let sha256: String
}

enum PluginPackageResolverError: LocalizedError, Equatable {
    case unsupportedPackageURL(URL)
    case missingLocalPackage(URL)
    case httpStatus(Int)
    case packageSizeMismatch(expected: Int64, actual: Int64)
    case packageTooLarge(Int64)
    case checksumMismatch(expected: String, actual: String)
    case unsupportedPackageFormat(URL)
    case invalidExpandedPackage
    case archiveEscapedDestination
    case manifestMismatch(field: String)
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedPackageURL(url):
            return AppL10n.pluginsFormat("plugin.error.package.unsupportedURLFormat", defaultValue: "插件包地址不支持：%@", url.absoluteString)
        case let .missingLocalPackage(url):
            return AppL10n.pluginsFormat("plugin.error.package.missingLocalFormat", defaultValue: "本地插件包不存在：%@", url.path)
        case let .httpStatus(statusCode):
            return AppL10n.pluginsFormat("plugin.error.package.httpStatusFormat", defaultValue: "插件包下载失败：HTTP %d", statusCode)
        case let .packageSizeMismatch(expected, actual):
            return AppL10n.pluginsFormat(
                "plugin.error.package.sizeMismatchFormat",
                defaultValue: "插件包大小不匹配，期望 %lld，实际 %lld。",
                expected,
                actual
            )
        case let .packageTooLarge(size):
            return AppL10n.pluginsFormat("plugin.error.package.tooLargeFormat", defaultValue: "插件包过大：%lld", size)
        case let .checksumMismatch(expected, actual):
            return AppL10n.pluginsFormat(
                "plugin.error.package.checksumMismatchFormat",
                defaultValue: "插件包校验失败，期望 %@，实际 %@。",
                expected,
                actual
            )
        case let .unsupportedPackageFormat(url):
            return AppL10n.pluginsFormat("plugin.error.package.unsupportedFormatFormat", defaultValue: "插件包格式不支持：%@", url.lastPathComponent)
        case .invalidExpandedPackage:
            return AppL10n.plugins("plugin.error.package.invalidExpanded", defaultValue: "插件压缩包内容无效。")
        case .archiveEscapedDestination:
            return AppL10n.plugins("plugin.error.package.unsafeArchivePath", defaultValue: "插件压缩包包含不安全路径。")
        case let .manifestMismatch(field):
            return AppL10n.pluginsFormat("plugin.error.package.manifestMismatchFormat", defaultValue: "插件包 manifest 与插件列表不一致：%@", field)
        case let .unzipFailed(reason):
            return AppL10n.pluginsFormat("plugin.error.package.unzipFailedFormat", defaultValue: "插件压缩包解压失败：%@", reason)
        }
    }
}

private enum PluginZipExtractor {
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
                throw PluginPackageResolverError.unzipFailed(message)
            }
        }.value
    }
}
