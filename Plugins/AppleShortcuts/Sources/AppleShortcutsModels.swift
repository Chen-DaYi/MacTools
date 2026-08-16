import Foundation

enum AppleShortcutsLimits {
    static let maximumTrackedShortcutCount = 512
}

struct AppleShortcutItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let maximumNameByteCount = 1_024

    let id: UUID
    var name: String
    var folderIDs: Set<UUID>

    init(id: UUID, name: String, folderIDs: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.folderIDs = folderIDs
    }

    var actionID: String { "run.\(id.uuidString.lowercased())" }
}

struct AppleShortcutFolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
}

struct AppleShortcutsDiscovery: Equatable, Sendable {
    var shortcuts: [AppleShortcutItem]
    var folders: [AppleShortcutFolder]
    var folderMemberships: [UUID: Set<UUID>]
    var failedFolderIDs: Set<UUID>

    static let empty = AppleShortcutsDiscovery(
        shortcuts: [],
        folders: [],
        folderMemberships: [:],
        failedFolderIDs: []
    )
}

struct AppleShortcutPolicy: Codable, Equatable, Sendable {
    var requiresConfirmation: Bool
    var allowsRunLink: Bool

    static let `default` = AppleShortcutPolicy(
        requiresConfirmation: true,
        allowsRunLink: false
    )
}

struct AppleShortcutTrackedRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var lastKnownName: String
    var lastKnownFolderIDs: Set<UUID>

    var actionID: String { "run.\(id.uuidString.lowercased())" }
}

struct AppleShortcutSyncedFolder: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var lastKnownName: String
    var memberIDs: Set<UUID>
}

struct AppleShortcutFolderSyncPreview: Equatable, Sendable {
    let memberIDs: Set<UUID>
    let additionIDs: Set<UUID>
    let excludedIDs: Set<UUID>
    let projectedTrackedCount: Int

    var exceedsLimit: Bool {
        projectedTrackedCount > AppleShortcutsLimits.maximumTrackedShortcutCount
    }
}

enum AppleShortcutsStoreError: Error, Equatable {
    case recoveryRequired
    case tooManyTrackedShortcuts
    case payloadTooLarge
    case invalidData
    case persistenceFailed
}

enum AppleShortcutRunStatus: Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

struct AppleShortcutRunRecord: Equatable, Identifiable, Sendable {
    let id: UUID
    let shortcutID: UUID
    let shortcutName: String
    let startedAt: Date
    var finishedAt: Date?
    var status: AppleShortcutRunStatus
    var exitCode: Int32?
    var standardOutput: String
    var standardError: String
    var message: String?
    var outputWasTruncated: Bool
}

enum AppleShortcutsListParser {
    enum ParseError: Error, Equatable {
        case duplicateIdentifier(UUID)
    }

    static let maximumLineByteCount = 4 * 1_024

    static func parse(_ output: String) throws -> [AppleShortcutItem] {
        var seen = Set<UUID>()
        var items: [AppleShortcutItem] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let item = parseLine(String(rawLine)) else { continue }
            guard seen.insert(item.id).inserted else {
                throw ParseError.duplicateIdentifier(item.id)
            }
            items.append(item)
        }
        return items
    }

    static func parseFolders(_ output: String) throws -> [AppleShortcutFolder] {
        try parse(output).map { AppleShortcutFolder(id: $0.id, name: $0.name) }
    }

    static func parseLine(_ line: String) -> AppleShortcutItem? {
        guard !line.isEmpty,
              line.utf8.count <= maximumLineByteCount,
              line.hasSuffix(")"),
              let open = line.lastIndex(of: "("),
              open > line.startIndex
        else { return nil }

        let separator = line.index(before: open)
        guard line[separator] == " " else { return nil }
        let name = String(line[..<separator])
        let identifierStart = line.index(after: open)
        let identifierEnd = line.index(before: line.endIndex)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= AppleShortcutItem.maximumNameByteCount,
              let id = UUID(uuidString: String(line[identifierStart..<identifierEnd]))
        else { return nil }
        return AppleShortcutItem(id: id, name: name)
    }
}

extension String {
    var appleShortcutsNilIfEmpty: String? { isEmpty ? nil : self }
}
