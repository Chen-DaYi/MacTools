import AppKit
import SwiftUI

extension LaunchpadGlassMaterial {
    /// View-layer mapping (the model file stays AppKit-free). Internal — not fileprivate —
    /// so the CaseIterable completeness test can cover every whitelist entry.
    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .launchpad: .fullScreenUI
        case .frosted: .popover
        case .hud: .hudWindow
        case .subtle: .underWindowBackground
        }
    }
}

/// A parameterised `NSVisualEffectView`, generalised from the former private
/// `FrostedGlassScrim`: the launcher's main glass backdrop (`.behindWindow`, samples the
/// desktop), the folder scrim (`.withinWindow`, frosts the grid below it) and the settings
/// preview card (`.withinWindow`, samples the mock gradient) all share it.
///
/// Two invariants (design §5.1/§5.4):
/// - `state` is pinned `.active`. `.followsWindowActiveState` would grey the material the
///   instant the overlay loses key — e.g. when the carry floating icon's child window appears.
/// - `alphaValue` stays 1.0 (a partially transparent effect view renders undefined per AppKit
///   docs); the adjustable "transparency" is the material choice + the separate dim layer.
///
/// `hitTest` returns nil so clicks pass through to the SwiftUI tap layers around it
/// (click-to-dismiss on the main backdrop, tap-to-close on the folder scrim).
struct LaunchpadGlassBackdrop: NSViewRepresentable {
    var material: LaunchpadGlassMaterial
    var blendingMode: NSVisualEffectView.BlendingMode
    var forcesDarkAppearance = false
    /// Rounds the *material itself* via `maskImage`. Known AppKit gotcha (design §5.4 #4):
    /// a behind-window blur may ignore the hosting view's `cornerRadius` layer mask and
    /// leak square blur past the corners. The layer mask only clips in-process layers
    /// (icons, labels, the dim Rectangle); the blur is composited by the WindowServer, so
    /// the effect view needs its own mask. The compact main backdrop passes
    /// `LaunchpadCompactPanelMetrics.cornerRadius` here; full-screen and within-window
    /// usages keep 0 (no mask).
    var cornerRadius: CGFloat = 0

    private final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Tracks the mask radius already applied to the NSView, so live updates (the settings
    /// preview re-renders per slider tick) don't rebuild an identical mask image each time.
    final class Coordinator {
        var appliedCornerRadius: CGFloat = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughEffectView()
        view.blendingMode = blendingMode
        view.state = .active
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Material/appearance update live (the settings preview re-renders as the user flips
        // styles); the blending mode never changes for a given usage site.
        apply(to: nsView, coordinator: context.coordinator)
    }

    /// Internal — not private — so tests can drive the config path without a SwiftUI Context.
    func apply(to view: NSVisualEffectView, coordinator: Coordinator) {
        view.material = material.nsMaterial
        // Deep preset (G2): force dark on the backdrop ONLY — setting it on the hosting view
        // would drag labels, the search field and panels into dark mode with it.
        view.appearance = forcesDarkAppearance ? NSAppearance(named: .darkAqua) : nil
        if coordinator.appliedCornerRadius != cornerRadius {
            view.maskImage = cornerRadius > 0 ? Self.roundedRectMaskImage(cornerRadius: cornerRadius) : nil
            coordinator.appliedCornerRadius = cornerRadius
        }
    }

    /// Resizable rounded-rect mask: cap insets pin the four corner arcs while the 1pt
    /// center stretches, so one tiny image masks the panel at any size. Internal for tests.
    static func roundedRectMaskImage(cornerRadius radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Recipe → preview fill, shared by the settings glass-preview card and the layout-preview
/// canvas (ruling G6: ONE implementation, the layout preview absorbs the glass recipe).
/// The same switch the real overlay's `backgroundLayer` performs, minus the dismiss tap
/// layer; within-window blending so it samples the mock desktop gradient behind it.
struct LaunchpadRecipeGlassFill: View {
    var recipe: LaunchpadBackgroundRecipe

    var body: some View {
        ZStack {
            switch recipe {
            case .legacyUltraThin:
                Rectangle().fill(.ultraThinMaterial)
            case .glass(let material, let dimOpacity, let forcesDark):
                LaunchpadGlassBackdrop(
                    material: material,
                    blendingMode: .withinWindow,
                    forcesDarkAppearance: forcesDark
                )
                Rectangle().fill(.black.opacity(dimOpacity))
            }
        }
    }
}

/// Desktop-ish gradient both settings previews lay under their glass — one source so the
/// two cards can't drift apart (the blur needs something colourful and legible to chew on).
struct LaunchpadDesktopMockGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.26, green: 0.42, blue: 0.86),
                Color(red: 0.56, green: 0.36, blue: 0.78),
                Color(red: 0.93, green: 0.62, blue: 0.40),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Compact floating-panel geometry shared across files so the two clips can never drift:
/// the host layer mask (`LaunchpadOverlayController.open()`, clips SwiftUI content) and the
/// backdrop `maskImage` (clips the behind-window blur) must use the same radius.
enum LaunchpadCompactPanelMetrics {
    static let cornerRadius: CGFloat = 22
}
