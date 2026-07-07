import Foundation

/// Persisted reference to one app inside a custom layout.
///
/// Identity is the resolved absolute path (`LaunchpadAppItem.id`) — the same key used by
/// `LaunchpadPreferences.hiddenAppIDs` and the icon cache, so hide / order / icon all agree
/// on one identity (design §2). `bundleID` is a reserved, currently-unused field kept only
/// so a future migration could add a secondary match key without a format break; v1 always
/// encodes `nil` and never reads it for matching.
struct LaunchpadAppRef: Codable, Hashable {
    var id: String
    var bundleID: String?
    var name: String

    init(id: String, bundleID: String? = nil, name: String) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
    }
}

/// One node in the (single-level) custom layout tree.
///
/// `folder.children` holds `LaunchpadAppRef` (not nodes), so "folder inside folder" is
/// unrepresentable at the type level — the same two-level constraint as macOS Launchpad.
/// 19a only ever produces `.app` nodes; the `.folder` case and its Codable exist now so the
/// persistence format is fixed once and 19b needs no second migration (design §3).
enum LaunchpadLayoutNode: Codable, Hashable {
    case app(LaunchpadAppRef)
    case folder(id: String, name: String, children: [LaunchpadAppRef])

    /// Root-level identity used for ordering and lookups: an `.app`'s path id, or a
    /// `.folder`'s UUID. App ids always start with `/`, folder ids are UUIDs, so the two
    /// namespaces never collide.
    var rootID: String {
        switch self {
        case .app(let ref): return ref.id
        case .folder(let id, _, _): return id
        }
    }

    /// Every app id this node references (the app id, or a folder's children ids). Used to
    /// tell which visible apps are already captured in the layout.
    var appIDs: [String] {
        switch self {
        case .app(let ref): return [ref.id]
        case .folder(_, _, let children): return children.map(\.id)
        }
    }

    // Hand-written, kind-discriminated coding (not Swift's automatic enum encoding) so new
    // fields or kinds can be added compatibly later.
    private enum Kind: String, Codable {
        case app
        case folder
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case app                    // .app payload
        case id, name, children     // .folder payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .app:
            self = .app(try container.decode(LaunchpadAppRef.self, forKey: .app))
        case .folder:
            self = .folder(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                children: try container.decode([LaunchpadAppRef].self, forKey: .children)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let ref):
            try container.encode(Kind.app, forKey: .kind)
            try container.encode(ref, forKey: .app)
        case .folder(let id, let name, let children):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(children, forKey: .children)
        }
    }
}

/// The user's custom ordering / grouping.
///
/// Its mere existence ("layout present") *is* the "custom sort" flag — there is no separate
/// `isCustomSorted` bool to fall out of sync (design §3). Absent (`nil`) == alphabetical.
/// `version` starts at 2 — version 1 is reserved for a hypothetical plain-`[String]` format
/// that never shipped, so any stored `version < currentVersion` is treated as unreadable.
struct LaunchpadLayout: Codable, Equatable {
    static let currentVersion = 2

    var version: Int
    var nodes: [LaunchpadLayoutNode]

    init(version: Int = LaunchpadLayout.currentVersion, nodes: [LaunchpadLayoutNode]) {
        self.version = version
        self.nodes = nodes
    }
}
