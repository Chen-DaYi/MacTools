import AppKit
import DiskArbitration
import Foundation

struct EjectableVolume: Equatable, Sendable {
    let mountURLs: [URL]
    let name: String
    let deviceIdentifier: String?
    let isLocal: Bool?

    init(
        mountURL: URL,
        name: String,
        deviceIdentifier: String? = nil,
        isLocal: Bool? = true
    ) {
        self.mountURLs = [mountURL]
        self.name = name
        self.deviceIdentifier = deviceIdentifier
        self.isLocal = isLocal
    }

    init(
        mountURLs: [URL],
        name: String,
        deviceIdentifier: String?,
        isLocal: Bool?
    ) {
        self.mountURLs = mountURLs
        self.name = name
        self.deviceIdentifier = deviceIdentifier
        self.isLocal = isLocal
    }

    var id: String {
        deviceIdentifier ?? mountURLs[0].standardizedFileURL.path
    }
}

enum EjectDiskService {
    private static let volumeResourceKeys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey,
        .volumeNameKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsLocalKey,
        .volumeIsBrowsableKey
    ]

    static func discoverMountedEjectableVolumes() async throws -> [EjectableVolume] {
        let worker = Task.detached(priority: .userInitiated) { () throws -> [EjectableVolume] in
            guard let mountedURLs = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(volumeResourceKeys),
                options: [.skipHiddenVolumes]
            ) else {
                throw EjectDiskServiceError.volumeEnumerationFailed
            }

            let diskArbitrationSession = DASessionCreate(kCFAllocatorDefault)
            var volumes: [EjectableVolume] = []
            for url in mountedURLs {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: volumeResourceKeys) else {
                    continue
                }

                var isRemovable = ObjCBool(false)
                var isWritable = ObjCBool(false)
                var isUnmountable = ObjCBool(false)
                let hasFileSystemInfo = NSWorkspace.shared.getFileSystemInfo(
                    forPath: url.path,
                    isRemovable: &isRemovable,
                    isWritable: &isWritable,
                    isUnmountable: &isUnmountable,
                    description: nil,
                    type: nil
                )
                guard shouldOfferEject(
                    mountPath: url.path,
                    isInternal: values.volumeIsInternal,
                    isRemovable: values.volumeIsRemovable == true || isRemovable.boolValue,
                    isEjectable: values.volumeIsEjectable,
                    isLocal: values.volumeIsLocal,
                    isUnmountable: hasFileSystemInfo && isUnmountable.boolValue,
                    isBrowsable: values.volumeIsBrowsable
                ) else {
                    continue
                }

                let name = values.volumeLocalizedName
                    ?? values.volumeName
                    ?? FileManager.default.displayName(atPath: url.path)
                volumes.append(EjectableVolume(
                    mountURL: url,
                    name: name,
                    deviceIdentifier: wholeDiskIdentifier(
                        for: url,
                        session: diskArbitrationSession
                    ),
                    isLocal: values.volumeIsLocal
                ))
            }
            return deduplicate(volumes)
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func shouldOfferEject(
        mountPath: String,
        isInternal: Bool?,
        isRemovable: Bool?,
        isEjectable: Bool?,
        isLocal: Bool?,
        isUnmountable: Bool,
        isBrowsable: Bool? = true
    ) -> Bool {
        guard mountPath != "/", isBrowsable != false else {
            return false
        }

        // Fixed external drives are often neither removable nor mechanically
        // ejectable. Finder still offers eject when the filesystem is unmountable.
        if isRemovable == true || isEjectable == true {
            return true
        }
        if isLocal == false {
            return isUnmountable
        }
        if isInternal == false {
            return true
        }
        return isInternal == nil && isUnmountable
    }

    static func deduplicate(_ volumes: [EjectableVolume]) -> [EjectableVolume] {
        var result: [EjectableVolume] = []
        var indexByID: [String: Int] = [:]

        for volume in volumes {
            guard let existingIndex = indexByID[volume.id] else {
                indexByID[volume.id] = result.count
                result.append(volume)
                continue
            }

            let existing = result[existingIndex]
            let knownPaths = Set(existing.mountURLs.map { $0.standardizedFileURL.path })
            let additionalURLs = volume.mountURLs.filter {
                !knownPaths.contains($0.standardizedFileURL.path)
            }
            result[existingIndex] = EjectableVolume(
                mountURLs: existing.mountURLs + additionalURLs,
                name: existing.name,
                deviceIdentifier: existing.deviceIdentifier,
                isLocal: existing.isLocal
            )
        }

        return result
    }

    static func eject(_ volume: EjectableVolume) async throws {
        guard let mountURL = volume.mountURLs.first(where: isMounted) else {
            return
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try NSWorkspace.shared.unmountAndEjectDevice(at: mountURL)
            }.value
            return
        } catch {
            guard isMounted(mountURL) else {
                return
            }

            if volume.isLocal == false {
                try await unmountVolume(at: mountURL)
                return
            }

            let result = try await runDiskutil(arguments: ["eject", mountURL.path])
            guard result.terminationStatus == 0 else {
                throw EjectDiskServiceError.ejectFailed(
                    primaryError: error.localizedDescription,
                    fallbackError: result.errorOutput
                )
            }
        }
    }

    private static func wholeDiskIdentifier(
        for url: URL,
        session: DASession?
    ) -> String? {
        guard
            let session,
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL)
        else {
            return nil
        }

        let wholeDisk = DADiskCopyWholeDisk(disk) ?? disk
        guard let bsdName = DADiskGetBSDName(wholeDisk) else {
            return nil
        }
        return String(cString: bsdName)
    }

    private static func isMounted(_ url: URL) -> Bool {
        let targetPath = url.standardizedFileURL.path
        return FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )?.contains { $0.standardizedFileURL.path == targetPath } == true
    }

    private static func unmountVolume(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FileManager.default.unmountVolume(at: url, options: []) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func runDiskutil(arguments: [String]) async throws -> DiskutilResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = arguments

            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return DiskutilResult(
                terminationStatus: process.terminationStatus,
                standardOutput: outputData,
                standardError: errorData
            )
        }.value
    }
}

private struct DiskutilResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var errorOutput: String {
        let error = String(data: standardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard error.isEmpty else { return error }
        return String(data: standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private enum EjectDiskServiceError: LocalizedError {
    case volumeEnumerationFailed
    case ejectFailed(primaryError: String, fallbackError: String)

    var errorDescription: String? {
        switch self {
        case .volumeEnumerationFailed:
            return "Unable to enumerate mounted volumes"
        case let .ejectFailed(primaryError, fallbackError):
            return fallbackError.isEmpty ? primaryError : fallbackError
        }
    }
}
