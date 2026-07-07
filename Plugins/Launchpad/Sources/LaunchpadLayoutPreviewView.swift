import AppKit
import SwiftUI
import MacToolsPluginKit

/// Layout thumbnail preview (design §4.2): the first row of the settings appearance group. Pure SwiftUI
/// over `LaunchpadLayoutPreviewModel` — all geometry comes from the model (which runs the
/// SAME `LaunchpadLayoutMath` pipeline as the live overlay), this view only draws.
///
/// Layers (ruling P1 — two layers in compact): mock desktop gradient (the "screen") →
/// the launcher window filled with the user's actual glass recipe (ruling G6 — the P0b
/// preview formula absorbed as the canvas floor) → search-bar capsule, full-page tile
/// placeholders and page dots, drawn in one `Canvas` so even a hidden-names 48pt page on
/// a large screen (hundreds of tiles) repaints cheaply on every slider tick.
struct LaunchpadLayoutPreviewView: View {
    @ObservedObject var preferences: LaunchpadPreferences
    let localization: PluginLocalization

    /// Fixed canvas height (≤ the design's 200pt cap); the screen aspect-fits inside,
    /// so window resizes rescale proportionally without layout jumps.
    private static let canvasHeight: CGFloat = 168
    /// Design §4.1 fallback when no screen is attachable (headless test hosts).
    private static let fallbackScreen = CGSize(width: 1512, height: 982)

    /// Representative screen geometry: the main screen's CURRENT frames (multi-display
    /// is not enumerated — same single-screen decision as the overlay; the caption is an
    /// estimate for this screen). TWO frames, mirroring `targetFrame(on:)` exactly:
    /// the physical `frame` (what the fullscreen overlay covers — menu bar and Dock
    /// included) plus the `visibleFrame` (what the compact panel centres on), converted
    /// from AppKit's bottom-left globals into top-left space relative to the frame.
    private var screenGeometry: (frame: CGSize, visible: CGRect) {
        guard let screen = NSScreen.main,
              screen.frame.width > 0, screen.frame.height > 0 else {
            return (Self.fallbackScreen, CGRect(origin: .zero, size: Self.fallbackScreen))
        }
        let frame = screen.frame
        let visible = screen.visibleFrame
        return (
            frame.size,
            CGRect(
                x: visible.minX - frame.minX,
                y: frame.maxY - visible.maxY,   // bottom-left global → top-left local
                width: visible.width,
                height: visible.height
            )
        )
    }

    private func model(canvas: CGSize) -> LaunchpadLayoutPreviewModel {
        let screen = screenGeometry
        return LaunchpadLayoutPreviewModel.make(
            appearance: preferences.appearance,
            mode: preferences.windowMode,
            fixedColumns: preferences.columns == LaunchpadPreferences.autoColumns
                ? nil : preferences.columns,
            compactScalePercent: preferences.compactScalePercent,
            screenFrame: screen.frame,
            visibleFrame: screen.visible,
            canvas: canvas
        )
    }

    var body: some View {
        // Capacity numbers depend only on the screen + preferences, never on the canvas
        // size (scale shrinks rects, not counts) — so the caption can derive from a
        // nominal-size model: same source, no GeometryReader value escape.
        let caption = model(canvas: CGSize(width: 100, height: 100))
        VStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            GeometryReader { geo in
                let model = model(canvas: CGSize(width: geo.size.width, height: geo.size.height))
                canvas(model)
                    // Centre the aspect-fit screen frame in the available row width.
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: Self.canvasHeight)
            // Caption carries the A4-clamp signal: the localized "columns x rows, items per page"
            // text is how a clamped fixed-column setting becomes visible (design §4.2).
            Text(localization.format(
                "settings.appearance.preview.caption",
                defaultValue: "%1$d 列 × %2$d 行 · 每页 %3$d 个",
                caption.columns, caption.rows, caption.perPage
            ))
            .font(PluginSettingsTheme.Typography.monospacedValue)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.format(
            "settings.appearance.preview.accessibility",
            defaultValue: "排列预览：当前设置每页 %1$d 列 %2$d 行，共 %3$d 个",
            caption.columns, caption.rows, caption.perPage
        ))
    }

    // MARK: - Canvas layers

    private func canvas(_ model: LaunchpadLayoutPreviewModel) -> some View {
        ZStack(alignment: .topLeading) {
            desktopBackdrop(model)
            // The launcher window, filled with the user's REAL glass recipe — in compact
            // this is the second, centred layer; in fullscreen it covers the screen frame.
            LaunchpadRecipeGlassFill(recipe: preferences.backgroundRecipe)
                .clipShape(RoundedRectangle(
                    cornerRadius: windowCornerRadius(model),
                    style: .continuous
                ))
                .frame(width: model.windowRect.width, height: model.windowRect.height)
                .offset(x: model.windowRect.minX, y: model.windowRect.minY)
            tileLayer(model)
        }
        .frame(width: model.screenSize.width, height: model.screenSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        // Model is Equatable → geometry layers tween on every preference change. (The
        // Canvas pass inside repaints instantly; only shape frames interpolate.)
        .animation(.easeOut(duration: 0.15), value: model)
        .frame(maxWidth: .infinity)
    }

    /// Mock desktop under the glass: shared gradient + two soft shapes placed
    /// proportionally so the blur reads at any canvas size.
    private func desktopBackdrop(_ model: LaunchpadLayoutPreviewModel) -> some View {
        ZStack(alignment: .topLeading) {
            LaunchpadDesktopMockGradient()
            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: model.screenSize.width * 0.18)
                .offset(x: model.screenSize.width * 0.12,
                        y: model.screenSize.height * 0.16)
            Circle()
                .fill(Color(red: 0.18, green: 0.65, blue: 0.45).opacity(0.8))
                .frame(width: model.screenSize.width * 0.13)
                .offset(x: model.screenSize.width * 0.68,
                        y: model.screenSize.height * 0.58)
        }
    }

    /// Compact rounds like the real panel (22pt scaled, floored so it stays visible at
    /// preview scale); fullscreen has square window corners (the screen clip rounds).
    private func windowCornerRadius(_ model: LaunchpadLayoutPreviewModel) -> CGFloat {
        preferences.windowMode == .compact
            ? max(3, LaunchpadCompactPanelMetrics.cornerRadius * model.scale)
            : 0
    }

    /// Search bar + one full page of tile placeholders + page dots, one Canvas pass.
    /// Translucent shapes only — no icons, no catalog IO (ruling P2).
    private func tileLayer(_ model: LaunchpadLayoutPreviewModel) -> some View {
        Canvas { context, _ in
            context.fill(
                Path(roundedRect: model.searchBarRect,
                     cornerRadius: model.searchBarRect.height / 2,
                     style: .continuous),
                with: .color(.white.opacity(0.22))
            )
            for tile in model.tiles {
                // Same corner ratio as the live selection squircle (0.24 × width).
                context.fill(
                    Path(roundedRect: tile.iconRect,
                         cornerRadius: tile.iconRect.width * 0.24,
                         style: .continuous),
                    with: .color(.white.opacity(0.16))
                )
                if let label = tile.labelRect {
                    // A thin centred bar standing in for the first text line.
                    let bar = CGRect(
                        x: label.midX - label.width * 0.3,
                        y: label.minY,
                        width: label.width * 0.6,
                        height: max(1.5, label.height * 0.28)
                    )
                    context.fill(
                        Path(roundedRect: bar, cornerRadius: bar.height / 2),
                        with: .color(.white.opacity(0.10))
                    )
                }
            }
            // Three decorative page dots in the indicator reserve, first one "current".
            let dotSide: CGFloat = 3.5
            let dotGap: CGFloat = 4.5
            for index in 0..<3 {
                let rect = CGRect(
                    x: model.pageDotsCenter.x + CGFloat(index - 1) * (dotSide + dotGap)
                        - dotSide / 2,
                    y: model.pageDotsCenter.y - dotSide / 2,
                    width: dotSide,
                    height: dotSide
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.white.opacity(index == 0 ? 0.65 : 0.3))
                )
            }
        }
        .allowsHitTesting(false)
    }
}
