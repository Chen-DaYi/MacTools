import Foundation
import MacToolsPluginKit

/// Pure model for the launcher's glass background (design 2026-06-11 §5). Deliberately
/// AppKit-free — the `NSVisualEffectView.Material` mapping lives in the view layer
/// (`LaunchpadGlassBackdrop.swift`) so this file stays a unit-testable value layer.
///
/// Presets resolve to a `LaunchpadBackgroundRecipe` via `recipe(customMaterial:customDimPercent:)`;
/// only the `.custom` style reads the two custom knobs (G3: 4-material whitelist, no separate
/// dark toggle — the deep preset owns forced-dark).
enum LaunchpadBackgroundStyle: String, CaseIterable, Identifiable {
    case clear
    case standard
    case deep
    case custom

    var id: String { rawValue }

    func label(localization: PluginLocalization) -> String {
        switch self {
        case .clear:
            localization.string("backgroundStyle.clear", defaultValue: "清透")
        case .standard:
            localization.string("backgroundStyle.standard", defaultValue: "标准")
        case .deep:
            localization.string("backgroundStyle.deep", defaultValue: "深邃")
        case .custom:
            localization.string("backgroundStyle.custom", defaultValue: "自定义")
        }
    }

    /// Preset → rendering recipe. Pure; safe to call from any context.
    ///
    /// G1 regression anchor: `.standard` (the default) resolves to `.legacyUltraThin`, the
    /// byte-identical pre-existing SwiftUI `.ultraThinMaterial` path — an untouched preference
    /// renders exactly like previous builds, no on-device calibration required. The design's
    /// `.fullScreenUI + 0.12` approximation remains reachable through the custom style.
    func recipe(
        customMaterial: LaunchpadGlassMaterial,
        customDimPercent: Int
    ) -> LaunchpadBackgroundRecipe {
        switch self {
        case .clear:
            .glass(material: .launchpad, dimOpacity: 0, forcesDarkAppearance: false)
        case .standard:
            .legacyUltraThin
        case .deep:
            // G2: forced dark applies to the backdrop ONLY, never the hosting view.
            .glass(material: .hud, dimOpacity: 0.28, forcesDarkAppearance: true)
        case .custom:
            .glass(
                material: customMaterial,
                dimOpacity: Double(LaunchpadBackgroundDim.normalized(customDimPercent)) / 100,
                forcesDarkAppearance: false
            )
        }
    }
}

/// Material whitelist for the custom style (G3). The excluded materials (`.sheet`, `.menu`,
/// `.windowBackground`, …) read as near-opaque chrome, not launcher glass.
enum LaunchpadGlassMaterial: String, CaseIterable, Identifiable {
    case launchpad      // → .fullScreenUI: what system full-screen UI (Mission Control) uses
    case frosted        // → .popover
    case hud            // → .hudWindow
    case subtle         // → .underWindowBackground

    var id: String { rawValue }

    func label(localization: PluginLocalization) -> String {
        switch self {
        case .launchpad:
            localization.string("backgroundMaterial.launchpad", defaultValue: "启动台")
        case .frosted:
            localization.string("backgroundMaterial.frosted", defaultValue: "磨砂")
        case .hud:
            localization.string("backgroundMaterial.hud", defaultValue: "深色面板")
        case .subtle:
            localization.string("backgroundMaterial.subtle", defaultValue: "柔和")
        }
    }
}

/// The full rendering description the overlay snapshots at `open()` and the settings
/// preview card mirrors. Two hard AppKit constraints shape it (design §5.1): an effect
/// view's `alphaValue` must stay 1.0 (partial transparency renders undefined), so the
/// user-facing "transparency" is material choice + this separate dim-layer opacity.
enum LaunchpadBackgroundRecipe: Equatable {
    /// The pre-change rendering: one SwiftUI `.ultraThinMaterial` fill, no dim layer.
    /// Kept as its own case so the default style is pixel-identical by construction (G1).
    case legacyUltraThin
    /// Parameterised `NSVisualEffectView` + black dim layer (`dimOpacity` 0...0.6).
    case glass(material: LaunchpadGlassMaterial, dimOpacity: Double, forcesDarkAppearance: Bool)
}

/// Dim-percent domain shared by the preference clamp and the recipe resolution.
enum LaunchpadBackgroundDim {
    static let percentRange: ClosedRange<Int> = 0...60
    static let defaultPercent = 12

    static func normalized(_ value: Int) -> Int {
        min(max(value, percentRange.lowerBound), percentRange.upperBound)
    }
}
