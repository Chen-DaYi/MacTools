import AppKit

/// Page-strip geometry snapshot pushed from the SwiftUI grid to the drag
/// coordinator. The viewport fields are in AppKit window space and describe the
/// *visible* page slot, which stays constant across page flips — the SwiftUI
/// paging `.offset` is a render-time transform that never enters the AppKit
/// frame chain, so cross-page math must come from this snapshot instead of
/// `convert(_:from:)` against an offset container.
struct LaunchpadPageGeometry: Equatable {
    var pageWidth: CGFloat = 0
    var gridHeight: CGFloat = 0
    var pageCount: Int = 1          // real page count (virtual tail page excluded)
    var perPage: Int = 1
    var viewportMinX: CGFloat = 0   // viewport left edge, AppKit window space
    var viewportTopY: CGFloat = 0   // grid top edge, AppKit window space (y anchor for flipped containers)
}

/// Explicit window-point ↔ page-local arithmetic for a carry session.
///
/// "Viewport is the page": the result is identical for whichever page is
/// currently visible, so callers feed exactly one container — the registered
/// current-page one — and never add per-page offsets here. Pure value type so
/// tests construct it directly (no window, no convert).
struct LaunchpadCarrySpace {
    let viewportMinX: CGFloat
    let viewportTopY: CGFloat
    let pageWidth: CGFloat

    /// Window point → page-local point (top-left origin, matching the flipped
    /// grid containers). Feeds both drop classification and the edge turner.
    func local(fromWindow w: NSPoint) -> NSPoint {
        NSPoint(x: w.x - viewportMinX, y: viewportTopY - w.y)
    }

    /// Page-local rect → window rect (settle flight target, §7.1).
    func windowRect(fromLocal r: CGRect) -> NSRect {
        NSRect(x: viewportMinX + r.minX, y: viewportTopY - r.maxY, width: r.width, height: r.height)
    }
}
