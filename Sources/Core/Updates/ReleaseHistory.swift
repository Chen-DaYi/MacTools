import Foundation

struct ReleaseHistory: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let releases: [ReleaseHistoryItem]

    static let empty = ReleaseHistory(schemaVersion: 1, releases: [])
    static let bundled = loadBundled()

    static func decode(_ data: Data) throws -> ReleaseHistory {
        let history = try JSONDecoder().decode(ReleaseHistory.self, from: data)
        guard history.schemaVersion == 1 else {
            throw ReleaseHistoryError.unsupportedSchema(history.schemaVersion)
        }
        return history
    }

    func mostRecentReleases(limit: Int) -> [ReleaseHistoryItem] {
        guard limit > 0 else { return [] }
        return Array(releases.prefix(limit))
    }

    static func loadBundled(in bundle: Bundle = .main) -> ReleaseHistory {
        guard let resourceURL = bundle.url(forResource: "ReleaseHistory", withExtension: "json") else {
            AppLog.releaseHistory.error("Bundled release history is missing")
            return .empty
        }

        do {
            return try decode(Data(contentsOf: resourceURL))
        } catch {
            AppLog.releaseHistory.error(
                "Cannot load bundled release history: \(error.localizedDescription, privacy: .public)"
            )
            return .empty
        }
    }
}

enum ReleaseHistoryError: Error, Equatable {
    case unsupportedSchema(Int)
}

struct ReleaseHistoryItem: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: ReleaseHistoryKind
    let version: String
    let date: String
    let sections: [ReleaseHistorySection]
}

enum ReleaseHistoryKind: String, Decodable, Equatable, Sendable {
    case app
    case plugin
}

struct ReleaseHistorySection: Decodable, Equatable, Identifiable, Sendable {
    let kind: ReleaseHistorySectionKind
    let entries: [String]

    var id: ReleaseHistorySectionKind {
        kind
    }
}

enum ReleaseHistorySectionKind: String, Decodable, Equatable, Hashable, Sendable {
    case summary
    case added
    case changed
    case deprecated
    case removed
    case fixed
    case security
    case maintenance

    var displayName: String {
        rawValue.capitalized
    }
}
