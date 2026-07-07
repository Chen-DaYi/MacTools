import AppKit
import MacToolsPluginKit

/// Pure model for the launcher's label appearance (design 2026-06-13). Three orthogonal
/// presets — color / weight / size — shared by grid labels (app names + collapsed folder
/// names, same `cell.label`) and the open-folder big title (which derives a slightly
/// heavier/larger style from the same selections).
///
/// Safe-default discipline (byte-compat): the defaults (`automatic` / `regular` /
/// `medium`) resolve to the historical hardcoded label rendering — `.labelColor`, the
/// system regular weight, 12pt at the 64pt icon — so an untouched preference renders
/// exactly like previous builds. Only non-default selections move the geometry.

/// Label text color preset. `automatic` resolves to `.labelColor` for zero migration.
enum LaunchpadLabelColor: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark
    case accent

    var id: String { rawValue }

    /// Preset → AppKit color. Pure; safe to call from any context.
    /// `.automatic` resolves to `NSColor.labelColor` — the historical implicit color, so
    /// the default selection is byte-identical to previous builds.
    var nsColor: NSColor {
        switch self {
        case .automatic:
            .labelColor
        case .light:
            .white
        case .dark:
            .black
        case .accent:
            .controlAccentColor
        }
    }

    func label(localization: PluginLocalization) -> String {
        switch self {
        case .automatic:
            localization.string("labelColor.automatic", defaultValue: "自动")
        case .light:
            localization.string("labelColor.light", defaultValue: "白色")
        case .dark:
            localization.string("labelColor.dark", defaultValue: "黑色")
        case .accent:
            localization.string("labelColor.accent", defaultValue: "强调色")
        }
    }
}

/// Label font-weight preset. `regular` matches the historical system regular weight.
enum LaunchpadLabelWeight: String, CaseIterable, Identifiable {
    case regular
    case medium
    case semibold
    case bold

    var id: String { rawValue }

    /// Preset → AppKit font weight. Pure.
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        }
    }

    /// The folder big title's weight: the user's selection floored at `.semibold` so the
    /// title is never thinner than the historical baseline, satisfying "title ≥ app name".
    var emphasized: NSFont.Weight {
        switch self {
        case .regular, .medium, .semibold:
            .semibold
        case .bold:
            .bold
        }
    }

    func label(localization: PluginLocalization) -> String {
        switch self {
        case .regular:
            localization.string("labelWeight.regular", defaultValue: "常规")
        case .medium:
            localization.string("labelWeight.medium", defaultValue: "中等")
        case .semibold:
            localization.string("labelWeight.semibold", defaultValue: "半粗")
        case .bold:
            localization.string("labelWeight.bold", defaultValue: "加粗")
        }
    }
}

/// Label font-size preset. `medium` (the default) derives 12pt at the historical 64pt
/// icon, pinning the byte-compat baseline; the other tiers scale with the icon side.
enum LaunchpadLabelSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// Preset → point size for a given icon side. Pure.
    /// - `small`: a fixed 11pt, independent of icon size (compact density).
    /// - `medium`: `clamp(round(iconSide * 0.18), 11, 15)` — 12pt @64pt pins the history.
    /// - `large`: `clamp(round(iconSide * 0.21), 12, 17)` — coordinates with the icon.
    func fontSize(iconSide: CGFloat) -> CGFloat {
        switch self {
        case .small:
            11
        case .medium:
            Self.clamp((iconSide * 0.18).rounded(), lower: 11, upper: 15)
        case .large:
            Self.clamp((iconSide * 0.21).rounded(), lower: 12, upper: 17)
        }
    }

    func label(localization: PluginLocalization) -> String {
        switch self {
        case .small:
            localization.string("labelSize.small", defaultValue: "小")
        case .medium:
            localization.string("labelSize.medium", defaultValue: "中")
        case .large:
            localization.string("labelSize.large", defaultValue: "大")
        }
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
