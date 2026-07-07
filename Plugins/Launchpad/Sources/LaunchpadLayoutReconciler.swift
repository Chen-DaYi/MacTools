import Foundation

/// Display-time expansion of one root grid slot (computed, never persisted).
///
/// App and folder cells share one render sequence; `id` is the cross-type stable key that
/// `ForEach` / AppKit diffing must use to avoid drag/animation misplacement (apps use their
/// path id, folders use `folder.<uuid>`, which can never collide with an absolute path).
enum LaunchpadDisplayCell: Identifiable, Equatable {
    case app(LaunchpadAppItem)
    case folder(id: String, name: String, items: [LaunchpadAppItem])

    var id: String {
        switch self {
        case .app(let item): return item.id
        case .folder(let fid, _, _): return "folder.\(fid)"
        }
    }

    /// The id the *store* keys on — an app's path, or a folder's bare UUID (not the `folder.`
    /// prefixed display id). Used for drag payloads and reorder targets.
    var layoutID: String {
        switch self {
        case .app(let item): return item.id
        case .folder(let fid, _, _): return fid
        }
    }

    var folderID: String? {
        if case .folder(let fid, _, _) = self { return fid }
        return nil
    }
}

/// Pure projection: alphabetical `catalog.apps` (the truth source) + an optional custom
/// `layout` + `hidden` ids → the ordered cells to render.
///
/// This is the whole "safe downstream projection" idea: the output element *set* always
/// equals `visible` — only the order differs — so the grid's paging / `selectedIndex`
/// clamping downstream needs zero changes (design §5.2). The function is pure and never
/// writes persistence; only explicit user actions mutate the layout.
enum LaunchpadLayoutReconciler {
    static func reconcile(
        apps: [LaunchpadAppItem],
        layout: LaunchpadLayout?,
        hidden: Set<String>
    ) -> [LaunchpadDisplayCell] {
        // 1. Hidden filtered first, prior to and independent of ordering (invariant 4).
        let visible = apps.filter { !hidden.contains($0.id) }

        // 2. No custom layout → alphabetical passthrough (default behaviour unchanged).
        guard let layout else { return visible.map(LaunchpadDisplayCell.app) }

        // 3. Emit in layout order; silently skip ids that are missing / hidden / uninstalled.
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cells: [LaunchpadDisplayCell] = []
        var referenced = Set<String>()
        cells.reserveCapacity(visible.count)

        for node in layout.nodes {
            switch node {
            case .app(let ref):
                // `referenced.insert(...).inserted` also collapses any accidental duplicate
                // ref so each id is emitted at most once (set stays == visible).
                guard let item = byID[ref.id], referenced.insert(ref.id).inserted else { continue }
                cells.append(.app(item))
            case .folder(let fid, let name, let children):
                // Resolve the folder's currently-visible children (skip missing / hidden /
                // already-placed). An empty folder — all children gone (uninstalled / hidden /
                // unmounted volume) — is dropped from the render but kept in the layout (the
                // tolerance window; only explicit user actions dissolve it). Design §5.2 / §7.
                var items: [LaunchpadAppItem] = []
                for child in children {
                    guard let item = byID[child.id], referenced.insert(child.id).inserted else { continue }
                    items.append(item)
                }
                guard !items.isEmpty else { continue }
                cells.append(.folder(id: fid, name: name, items: items))
            }
        }

        // 4. Newly-installed apps (in `visible`, not referenced by the layout) append at the
        //    root tail. `visible` is already alphabetical, so iterating it keeps the tail
        //    alphabetical too (invariant 2).
        for item in visible where !referenced.contains(item.id) {
            cells.append(.app(item))
        }

        return cells
    }
}
