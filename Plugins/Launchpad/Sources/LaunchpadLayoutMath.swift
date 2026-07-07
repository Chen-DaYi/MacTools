import AppKit

/// Appearance preference snapshot (design §1.2) — the single input to
/// `LaunchpadGridMetrics.resolve(_:)` and, later, the settings layout preview.
/// Features 7/8 (hide names / icon size) own the writes; everything else only consumes.
struct LaunchpadAppearance: Equatable {
    /// Feature 8: 48...96pt, step 4. Default mirrors the long-standing 64pt icon.
    var iconSide: CGFloat = 64
    /// Feature 7: `!hidesAppNames`. Default = labels visible (today's behaviour).
    var showsLabels: Bool = true
    /// Label-style presets (design 2026-06-13). Defaults reproduce the historical implicit
    /// rendering — `.automatic` (→ `.labelColor`), regular weight, the `.medium` size tier
    /// (12pt at the default 64pt icon) — so an untouched appearance is byte-compatible.
    var labelColor: LaunchpadLabelColor = .automatic
    var labelWeight: LaunchpadLabelWeight = .regular
    var labelSize: LaunchpadLabelSize = .medium
}

extension LaunchpadGridMetrics {
    /// The ONLY resolution entry point from appearance preferences to grid metrics.
    /// Regression anchor (design §1.2): `resolve(LaunchpadAppearance())` must equal
    /// `LaunchpadGridMetrics()` field by field — the default appearance reproduces the
    /// historical hardcoded layout byte for byte.
    ///
    /// Derivation (@64pt check): labels shown → cellWidth = iconSide + 52 = 116,
    /// cellHeight = 8 + iconSide + 8 + 32 + 12 = iconSide + 60 = 124. Labels hidden
    /// (ruling A3, tightened) → cellWidth = iconSide + 28, cellHeight = 8 + iconSide
    /// + 12 = iconSide + 20, labelHeight = 0. Fixed chrome rather than a scale factor:
    /// at 48pt the label still fits two lines; at 96pt density approaches iOS.
    /// Spacing stays fixed in v1 (ruling A7); the parameters reserve the slot.
    static func resolve(
        _ appearance: LaunchpadAppearance,
        columnSpacing: CGFloat = 8,
        rowSpacing: CGFloat = 16
    ) -> LaunchpadGridMetrics {
        let iconSide = appearance.iconSide
        let showsLabels = appearance.showsLabels
        // Label-style derivation (design 2026-06-13). Font size scales with the icon per the
        // chosen tier; the grid label height only grows for the larger tiers — at the default
        // `.medium` size (12pt @64pt) it stays exactly 32, the byte-compat anchor.
        let labelFontSize = appearance.labelSize.fontSize(iconSide: iconSide)
        let labelFontWeight = appearance.labelWeight.nsFontWeight
        let labelHeight: CGFloat = showsLabels
            ? Self.labelHeight(forFontSize: labelFontSize, weight: labelFontWeight)
            : 0
        // The open-folder big title never drops below the historical `.title2`/semibold style
        // and is always ≥ the grid label, so a larger app-name size pushes the title up too.
        let folderTitleFontSize = max(Self.defaultFolderTitleFontSize, labelFontSize)
        let folderTitleWeight = appearance.labelWeight.emphasized
        return LaunchpadGridMetrics(
            cellWidth: iconSide + (showsLabels ? 52 : 28),
            cellHeight: iconSide + (showsLabels ? 60 : 20),
            iconSide: iconSide,
            columnSpacing: columnSpacing,
            rowSpacing: rowSpacing,
            showsLabels: showsLabels,
            iconTopInset: 8,
            labelGap: 8,
            labelHeight: labelHeight,
            labelColor: appearance.labelColor,
            labelFontSize: labelFontSize,
            labelFontWeight: labelFontWeight,
            folderTitleFontSize: folderTitleFontSize,
            folderTitleWeight: folderTitleWeight
        )
    }

    /// Two-line label strip height for a given font size/weight: `max(32, ceil(lineHeight × 2))`.
    /// The 32 floor pins the historical height, so the default `.medium` size (12pt, line
    /// height 15) and every tier up to 13pt stay at exactly 32 — only 15pt+ (the larger tiers
    /// at big icons) grow the strip. Returns 32 verbatim at the historical font, so the
    /// byte-compat anchor holds.
    static func labelHeight(forFontSize size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return max(32, ceil(lineHeight * 2))
    }

    /// The icon area inside a cell, in CELL-LOCAL coordinates — the single source for
    /// the live `LaunchpadGridCellView` AND the settings layout preview. Extracted for
    /// the same anti-drift reason as `Chrome`: a mirrored copy of this formula in the
    /// preview would drift silently the day the cell layout changes.
    var iconFrameInCell: CGRect {
        CGRect(
            x: (cellWidth - iconSide) / 2,
            y: iconTopInset,
            width: iconSide,
            height: iconSide
        )
    }

    /// The label strip below the icon, cell-local (2pt side insets, `labelGap` under
    /// the icon). With labels hidden the height collapses to 0 — the live cell hides
    /// the field, the preview drops the bar.
    var labelFrameInCell: CGRect {
        CGRect(
            x: 2,
            y: iconTopInset + iconSide + labelGap,
            width: cellWidth - 4,
            height: labelHeight
        )
    }
}

/// Pure layout math shared by the real launcher views and (P3) the settings preview —
/// one source of truth, so WYSIWYG is a structural guarantee, not a convention
/// (design §1.2). No view state, no side effects: everything here is unit-testable.
enum LaunchpadLayoutMath {
    /// Chrome constants pulled out of `LaunchpadGridView.body` / `updateLayout` so the
    /// live view and the preview read the SAME numbers (design §1.1 — anti-drift).
    struct Chrome: Equatable {
        var searchBarWidth: CGFloat
        var searchBarHeight: CGFloat
        /// VStack spacing between the search bar and the paged grid.
        var stackSpacing: CGFloat
        var topPadding: CGFloat
        var bottomPadding: CGFloat
        var horizontalPadding: CGFloat
        /// Height reserved below the grid for the page-indicator row (shared by
        /// `pageGrid` and the preview's "subtract chrome" math).
        static let pageIndicatorReserve: CGFloat = 26

        static func standard(isCompact: Bool) -> Chrome {
            Chrome(
                searchBarWidth: 360,
                searchBarHeight: 28,
                stackSpacing: isCompact ? 14 : 20,
                topPadding: isCompact ? 24 : 60,
                bottomPadding: isCompact ? 20 : 32,
                horizontalPadding: isCompact ? 24 : 48
            )
        }
    }

    /// The compact panel's frame on `visible` (the screen's `visibleFrame`).
    ///
    /// Production (P2) runs the scaled branch: `scalePercent` of the visible width, a
    /// 4×3-grid floor that rises with the icon size, a 95% ceiling — and NO 960×680
    /// hard cap (design §3.3, ruling A5 — a deliberate behaviour change: any screen
    /// whose visibleFrame exceeds ~1333×829pt gets a proportionally larger panel, and
    /// that includes ALL modern built-in laptop displays at default scaled resolution,
    /// not just external monitors — final-review scope correction; the window-size
    /// slider is the dial). The `legacyCap: true` branch keeps the historical
    /// `min(960, w × 0.72) × min(680, h × 0.82)` formula reproducible for the
    /// equivalence tests.
    static func compactFrame(
        visible: NSRect,
        scalePercent: Int = 72,
        metrics: LaunchpadGridMetrics = LaunchpadGridMetrics(),
        legacyCap: Bool = true
    ) -> NSRect {
        let width: CGFloat
        let height: CGFloat
        if legacyCap {
            width = min(960, visible.width * 0.72)
            height = min(680, visible.height * 0.82)
        } else {
            let s = CGFloat(scalePercent) / 100
            // Floor: a 4-column × 3-row grid plus chrome must always fit (§3.3), so a
            // bigger icon raises the floor and the panel can never shrink below 4×3.
            // The width floor back-adds a FOURTH columnSpacing on purpose: `pageGrid`'s
            // byte-compat `columnsThatFit` divides by the full pitch (cellWidth +
            // columnSpacing) without crediting the last column's missing trailing gap,
            // so "4 cells + 3 gaps" floors at only 3 columns. The rows formula already
            // gets this credit from its `+ rowSpacing` numerator, hence 2 rowSpacings
            // suffice there. (48 = 2 × compact horizontalPadding; 112 = compact vertical
            // chrome 86 + the 26pt page-indicator reserve.)
            let minW = 4 * (metrics.cellWidth + metrics.columnSpacing) + 48
            let minH = 3 * metrics.cellHeight + 2 * metrics.rowSpacing + 112
            width = min(max(visible.width * s, minW), visible.width * 0.95)
            height = min(max(visible.height * min(s + 0.10, 0.92), minH), visible.height * 0.95)
        }
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// Window size → the paged grid's viewport (what `LaunchpadGridView`'s
    /// GeometryReader measures): subtract the outer paddings, the search bar and the
    /// VStack spacing. The page-indicator reserve deliberately stays inside `pageGrid`,
    /// exactly like the live view (the GeometryReader wraps grid + dots together).
    static func gridViewport(mode: LaunchpadPreferences.WindowMode, windowSize: CGSize) -> CGSize {
        let chrome = Chrome.standard(isCompact: mode == .compact)
        return CGSize(
            width: max(0, windowSize.width - 2 * chrome.horizontalPadding),
            height: max(0, windowSize.height - chrome.topPadding - chrome.bottomPadding
                - chrome.searchBarHeight - chrome.stackSpacing)
        )
    }

    /// Folder-panel plate width cap (design §1.1: 5 columns + the 30pt padding ring),
    /// replacing the historical `maxWidth: 760` literal a 96pt icon row would overflow
    /// (5 × 148 + 32 = 772 > 760). Pass the FOLDER metrics (labels always shown, ruling
    /// A1). At the default 64pt this is 672 — a deliberate P2 appearance change from
    /// 760 (the plate now hugs its content); at 96pt it is 832 (pinned in tests).
    static func folderPanelMaxWidth(metrics: LaunchpadGridMetrics) -> CGFloat {
        5 * metrics.cellWidth + 4 * metrics.columnSpacing + 60
    }

    /// Offset (relative to a panel CENTRED in the ZStack) that lands the panel's centre on the
    /// opened folder's grid cell — the "from the cell" anchor for the iOS-style pop-out
    /// (animation design 2026-06-13). Pure SwiftUI viewport coordinates, zero AppKit `convert`
    /// (the y-flip / scale-transform sampling traps are avoided by never crossing the bridge).
    ///
    /// `cellRect` is the slot frame from `slotRect` — top-left origin, y-down, exactly the SwiftUI
    /// orientation. `Δ` shifts grid-container space into ZStack space: the grid begins below the
    /// chrome (search bar + paddings + VStack spacing), so the cell centre in the viewport is
    /// `Δ + cellRect.mid`. Subtracting the viewport centre gives the offset a centred panel needs.
    /// Δ is derived from `chrome` — never hard-coded literals, since compact / fullscreen differ.
    static func folderCollapsedOffset(
        cellRect: CGRect,
        chrome: Chrome,
        viewportSize: CGSize
    ) -> CGSize {
        let deltaX = chrome.horizontalPadding
        let deltaY = chrome.topPadding + chrome.searchBarHeight + chrome.stackSpacing
        let cellCenterX = deltaX + cellRect.midX
        let cellCenterY = deltaY + cellRect.midY
        return CGSize(
            width: cellCenterX - viewportSize.width / 2,
            height: cellCenterY - viewportSize.height / 2
        )
    }

    /// The frame of grid slot `index` (row-major) inside a top-aligned container of
    /// `containerWidth`: the grid block is horizontally centred with a FLOORED left
    /// inset (whole-point cell origins, exactly like the live container). Shared by
    /// `LaunchpadGridContainerView.slotRect` and the settings preview model — one
    /// source, so the preview matches the live grid to the point.
    static func slotRect(
        index: Int,
        columns: Int,
        containerWidth: CGFloat,
        metrics: LaunchpadGridMetrics
    ) -> CGRect {
        let columns = max(1, columns)
        let gridWidth = CGFloat(columns) * metrics.cellWidth
            + CGFloat(columns - 1) * metrics.columnSpacing
        let leftInset = max(0, (containerWidth - gridWidth) / 2).rounded(.down)
        let col = index % columns, row = index / columns
        return CGRect(
            x: leftInset + CGFloat(col) * (metrics.cellWidth + metrics.columnSpacing),
            y: CGFloat(row) * (metrics.cellHeight + metrics.rowSpacing),
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
    }

    /// Page capacity — `LaunchpadGridView.updateLayout(size:)` made pure, algorithm
    /// byte-compatible. `fixedColumns == nil` fits columns to the width.
    ///
    /// `clampsOverflowingFixedColumns` defaults to `true` since P2 (ruling A4): a fixed
    /// column count that cannot fit the width — reachable now that icons scale to 96pt —
    /// is silently clamped to what fits (the settings preview's "N × M" caption is the
    /// user-facing signal). Pass `false` only to reproduce the pre-P2 overflow behaviour
    /// (kept for the legacy-equivalence proof in tests).
    static func pageGrid(
        viewport: CGSize,
        metrics: LaunchpadGridMetrics,
        fixedColumns: Int?,
        clampsOverflowingFixedColumns: Bool = true
    ) -> (columns: Int, rows: Int) {
        func columnsThatFit(_ width: CGFloat) -> Int {
            let usable = max(width, metrics.cellWidth)
            return max(1, Int(usable / (metrics.cellWidth + metrics.columnSpacing)))
        }
        let columns: Int
        if let fixed = fixedColumns {
            let requested = max(1, fixed)
            columns = clampsOverflowingFixedColumns
                ? min(requested, columnsThatFit(viewport.width))
                : requested
        } else {
            columns = columnsThatFit(viewport.width)
        }
        // Reserve ~26pt for the page indicator row below the grid.
        let usableHeight = max(metrics.cellHeight, viewport.height - Chrome.pageIndicatorReserve)
        let rows = max(1, Int((usableHeight + metrics.rowSpacing) / (metrics.cellHeight + metrics.rowSpacing)))
        return (columns, rows)
    }
}
