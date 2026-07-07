import Foundation

/// Settings layout-preview geometry (design §4.1): a PURE derivation from the appearance
/// preferences to scaled preview rects — the view only draws, never computes.
///
/// Every capacity/geometry number flows through the SAME `LaunchpadLayoutMath` pipeline
/// the live overlay runs (`resolve → compactFrame → gridViewport → pageGrid → slot math`),
/// so WYSIWYG is a structural guarantee, not a convention. The model owns no persistence
/// and performs no IO: it projects the preference values it is handed and never reads the
/// app catalog (ruling P2 — the preview shows page CAPACITY, not the current census).
struct LaunchpadLayoutPreviewModel: Equatable {
    struct Tile: Equatable {
        var iconRect: CGRect
        /// nil when app names are hidden (feature 7) — the view drops the label bar.
        var labelRect: CGRect?
    }

    /// The scaled "screen" frame (origin .zero in the preview's coordinate space, top-left).
    var screenSize: CGSize
    /// The scaled launcher window. Fullscreen: == the whole screen frame. Compact: the
    /// centred panel drawn as a SECOND layer over the screen frame (ruling P1 — two
    /// layers, which also visualises the window-size slider for free).
    var windowRect: CGRect
    /// Scaled search-bar placeholder, positioned from `Chrome` — the same constants the
    /// live view reads, so the preview cannot drift from the real chrome.
    var searchBarRect: CGRect
    /// One FULL page of placeholders, rows × columns, row-major.
    var tiles: [Tile]
    var columns: Int
    var rows: Int
    /// Scaled centre of the page-indicator dot row (inside `Chrome.pageIndicatorReserve`).
    var pageDotsCenter: CGPoint
    /// Preview points per screen point — uniform on both axes (aspect-fit).
    var scale: CGFloat

    /// The caption's "K per page" — and the A4 clamp's user-facing signal: when a fixed
    /// column count cannot fit (e.g. 12 × 96pt icons), `pageGrid` clamps silently and
    /// these numbers are how the user learns the effective layout.
    var perPage: Int { columns * rows }

    /// - Parameters:
    ///   - appearance: the normalized appearance snapshot (`LaunchpadPreferences.appearance`).
    ///   - fixedColumns: nil = auto columns; otherwise the user's fixed count (pre-clamp).
    ///   - compactScalePercent: the normalized window-size percentage; ignored in fullscreen.
    ///   - screenFrame: the representative screen's PHYSICAL frame size (`NSScreen.frame`)
    ///     — what the real fullscreen overlay covers, and the drawn screen canvas.
    ///   - visibleFrame: the screen's visible area (menu bar/Dock removed) expressed in
    ///     this model's TOP-LEFT space relative to `screenFrame` — what the real compact
    ///     panel centres on. The two sources mirror `LaunchpadOverlayController.targetFrame(on:)`
    ///     exactly; feeding one size to both modes made the fullscreen caption drop a
    ///     row/column vs the real launchpad on the very same screen.
    ///   - canvas: the available preview area; the screen frame aspect-fits into it.
    static func make(
        appearance: LaunchpadAppearance,
        mode: LaunchpadPreferences.WindowMode,
        fixedColumns: Int?,
        compactScalePercent: Int,
        screenFrame: CGSize,
        visibleFrame: CGRect,
        canvas: CGSize
    ) -> LaunchpadLayoutPreviewModel {
        // Degenerate inputs (a zero-size GeometryReader pass, a missing screen) fall back
        // to safe positives so nothing below divides by zero or returns NaN rects.
        let screen = CGSize(width: max(screenFrame.width, 320), height: max(screenFrame.height, 200))
        let screenRect = CGRect(origin: .zero, size: screen)
        // The visible area must be a positive rect inside the (possibly clamped) screen
        // frame; anything else — a zero rect from a headless host, a stale value after
        // the frame fallback kicked in — degrades to the whole frame.
        let visible = visibleFrame.width > 0 && visibleFrame.height > 0
            && screenRect.contains(visibleFrame) ? visibleFrame : screenRect
        let scale = max(0.001, min(canvas.width / screen.width, canvas.height / screen.height))

        // The production pipeline, verbatim (design §4.1):
        // resolve → (compactFrame) → gridViewport → pageGrid.
        let metrics = LaunchpadGridMetrics.resolve(appearance)
        let window: CGRect
        switch mode {
        case .fullscreen:
            // Frame parity with `targetFrame(on:)`: the real fullscreen overlay covers
            // `screen.frame` (menu bar and Dock included), NOT the visible frame.
            window = screenRect
        case .compact:
            // Frame parity again: the real compact panel centres `compactFrame` on
            // `screen.visibleFrame`. `visible` is already in this top-left space, and
            // centring survives the coordinate flip (centres map to centres), so the
            // returned rect reads directly here.
            window = LaunchpadLayoutMath.compactFrame(
                visible: visible,
                scalePercent: compactScalePercent,
                metrics: metrics,
                legacyCap: false
            )
        }
        let chrome = LaunchpadLayoutMath.Chrome.standard(isCompact: mode == .compact)
        let viewport = LaunchpadLayoutMath.gridViewport(mode: mode, windowSize: window.size)
        let grid = LaunchpadLayoutMath.pageGrid(
            viewport: viewport,
            metrics: metrics,
            fixedColumns: fixedColumns
        )

        // Grid viewport origin inside the window — mirrors `LaunchpadGridView.body`'s
        // VStack: top padding, then the search bar, then the stack spacing.
        let viewportOrigin = CGPoint(
            x: window.minX + chrome.horizontalPadding,
            y: window.minY + chrome.topPadding + chrome.searchBarHeight + chrome.stackSpacing
        )
        // Tile geometry comes from the SAME functions the live grid lays out with —
        // `LaunchpadLayoutMath.slotRect` (incl. the floored centring inset) and the
        // cell-local `iconFrameInCell` / `labelFrameInCell`. Shared source, not
        // mirrored formulas: a cell-layout change moves both surfaces together.
        var tiles: [Tile] = []
        tiles.reserveCapacity(grid.columns * grid.rows)
        for index in 0..<(grid.columns * grid.rows) {
            let slot = LaunchpadLayoutMath.slotRect(
                index: index,
                columns: grid.columns,
                containerWidth: viewport.width,
                metrics: metrics
            ).offsetBy(dx: viewportOrigin.x, dy: viewportOrigin.y)
            let icon = metrics.iconFrameInCell.offsetBy(dx: slot.minX, dy: slot.minY)
            let label: CGRect? = metrics.showsLabels
                ? metrics.labelFrameInCell.offsetBy(dx: slot.minX, dy: slot.minY)
                : nil
            tiles.append(Tile(
                iconRect: icon.scaled(by: scale),
                labelRect: label.map { $0.scaled(by: scale) }
            ))
        }

        let searchBar = CGRect(
            x: window.midX - chrome.searchBarWidth / 2,
            y: window.minY + chrome.topPadding,
            width: chrome.searchBarWidth,
            height: chrome.searchBarHeight
        )
        // The dot row sits at the bottom of the grid viewport, inside the 26pt reserve
        // `pageGrid` subtracts — i.e. just above the window's bottom padding.
        let pageDotsCenter = CGPoint(
            x: window.midX,
            y: window.maxY - chrome.bottomPadding
                - LaunchpadLayoutMath.Chrome.pageIndicatorReserve / 2
        )

        return LaunchpadLayoutPreviewModel(
            screenSize: CGSize(width: screen.width * scale, height: screen.height * scale),
            windowRect: window.scaled(by: scale),
            searchBarRect: searchBar.scaled(by: scale),
            tiles: tiles,
            columns: grid.columns,
            rows: grid.rows,
            pageDotsCenter: pageDotsCenter.scaled(by: scale),
            scale: scale
        )
    }
}

private extension CGRect {
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}

private extension CGPoint {
    func scaled(by factor: CGFloat) -> CGPoint {
        CGPoint(x: x * factor, y: y * factor)
    }
}
