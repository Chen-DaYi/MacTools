import Foundation

/// A bounded, memory-pressure-aware cache for Apple Shortcuts icon bitmaps.
///
/// Icon bytes are intentionally kept out of `AppleShortcutItem`/`AppleShortcutVisualMetadata`
/// because they are only needed while the settings workspace is visible; storing them in the
/// cache instead of the discovery snapshot keeps that snapshot cheap to copy and lets callers
/// discard every cached icon in one step when the settings page closes.
@MainActor
final class AppleShortcutsIconCache {
    /// Icons are downscaled and re-encoded before being cached (see
    /// `AppleShortcutsVisualMetadataLoader`), so this budget only needs to comfortably cover the
    /// settings list without letting a pathological icon inflate the app's resident memory.
    static let defaultTotalCostLimit = 16 * 1_024 * 1_024

    private let cache = NSCache<NSUUID, NSData>()

    init(totalCostLimit: Int = AppleShortcutsIconCache.defaultTotalCostLimit) {
        cache.totalCostLimit = totalCostLimit
    }

    func data(for shortcutID: UUID) -> Data? {
        cache.object(forKey: shortcutID as NSUUID) as Data?
    }

    func store(_ data: Data, for shortcutID: UUID) {
        cache.setObject(data as NSData, forKey: shortcutID as NSUUID, cost: data.count)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
