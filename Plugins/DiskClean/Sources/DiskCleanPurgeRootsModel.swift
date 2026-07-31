import Foundation

/// UI state for developer-artifact scan roots (design §10.1 settings area).
///
/// Collapses "storage + rejection feedback + scan-scope change notification" into one place:
/// the view only issues commands and reads state, while rejection reasons (unresolvable /
/// duplicate / covered by ancestor) need somewhere to live until the next render—
/// after `DiskCleanPurgeRootsStore.add` returns nobody remembers them, and users would think the
/// folder they just chose vanished.
@MainActor
final class DiskCleanPurgeRootsModel: ObservableObject {
    /// Normalized physical paths, in add order.
    @Published private(set) var roots: [String]
    /// Entries rejected by the most recent add/remove. Cleared by any successful operation.
    @Published private(set) var rejections: [DiskCleanPurgeRootRejection]

    /// Callback when the root set changes. Used to push the new scope to the developer-artifacts
    /// Controller—once scope changes the result must be marked stale; this wire must not break.
    var onRootsChange: (([String]) -> Void)?

    private let store: DiskCleanPurgeRootsStore

    init(store: DiskCleanPurgeRootsStore = DiskCleanPurgeRootsStore()) {
        self.store = store
        self.roots = store.roots()
        self.rejections = []
    }

    var scope: DiskCleanScanScope {
        .developerArtifacts(roots: roots)
    }

    var isEmpty: Bool { roots.isEmpty }

    func add(_ path: String) {
        apply(store.add(path))
    }

    func remove(_ path: String) {
        // Remove never produces rejections: if the path is not in the table the result is unchanged,
        // with nothing to explain.
        update(roots: store.remove(path), rejections: [])
    }

    /// User dismisses the reason after reading it. Do not auto-timeout—rejection means the user's
    /// intent was not met, so they must confirm they saw the message.
    func dismissRejections() {
        guard !rejections.isEmpty else { return }
        rejections = []
    }

    private func apply(_ update: DiskCleanPurgeRootsUpdate) {
        self.update(roots: update.roots, rejections: update.rejections)
    }

    private func update(roots: [String], rejections: [DiskCleanPurgeRootRejection]) {
        self.rejections = rejections
        guard roots != self.roots else { return }
        self.roots = roots
        onRootsChange?(roots)
    }
}
