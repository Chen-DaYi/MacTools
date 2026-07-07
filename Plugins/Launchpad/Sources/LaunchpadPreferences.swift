import Combine
import CoreGraphics
import MacToolsPluginKit

/// User-tunable launcher settings, persisted in the plugin's scoped `PluginStorage`
/// (survives relaunch). Owned by the plugin and shared with the overlay + settings view.
@MainActor
final class LaunchpadPreferences: ObservableObject {
    enum WindowMode: String, CaseIterable, Identifiable {
        case fullscreen
        case compact

        var id: String { rawValue }

        func label(localization: PluginLocalization) -> String {
            switch self {
            case .fullscreen:
                localization.string("windowMode.fullscreen", defaultValue: "全屏")
            case .compact:
                localization.string("windowMode.compact", defaultValue: "紧凑窗口")
            }
        }
    }

    /// Screen corner that summons the launcher when the cursor dwells there. `off` = none.
    enum HotCorner: String, CaseIterable, Identifiable {
        case off
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var id: String { rawValue }

        func label(localization: PluginLocalization) -> String {
            switch self {
            case .off:
                localization.string("hotCorner.off", defaultValue: "关闭")
            case .topLeft:
                localization.string("hotCorner.topLeft", defaultValue: "左上")
            case .topRight:
                localization.string("hotCorner.topRight", defaultValue: "右上")
            case .bottomLeft:
                localization.string("hotCorner.bottomLeft", defaultValue: "左下")
            case .bottomRight:
                localization.string("hotCorner.bottomRight", defaultValue: "右下")
            }
        }
    }

    /// `columns == autoColumns` means "fit to width"; otherwise a fixed count.
    static let autoColumns = 0
    static let minColumns = 4
    static let maxColumns = 12

    /// Icon size bounds (design §3.1, ruling A2): 48...96pt in 4pt steps, default 64.
    /// `integer(forKey:)` returns 0 when unset → the 0 sentinel maps to the default.
    static let defaultIconSize = 64
    static let minIconSize = 48
    static let maxIconSize = 96
    static let iconSizeStep = 4

    /// Compact-panel width as a percentage of the screen's visibleFrame (ruling A6):
    /// 55...90%, default 72. A5 scope correction (final review): 72% matches the historical
    /// frame only where the old 960×680 cap did NOT bind — visibleFrame ≤ ~1333pt wide and
    /// ≤ ~829pt tall. Every modern built-in laptop screen at default scaled resolution
    /// exceeds the width threshold (14" MBP 1512pt, 13.6" Air 1470pt, 16" MBP 1728pt), so
    /// compact-mode users there see a ~13% larger panel after the cap removal; the
    /// window-size slider is the dial back down.
    static let defaultCompactScale = 72
    static let minCompactScale = 55
    static let maxCompactScale = 90

    @Published var windowMode: WindowMode {
        didSet { storage.set(windowMode.rawValue, forKey: Keys.windowMode) }
    }

    @Published var columns: Int {
        didSet {
            // Clamp on the single write path so no out-of-range value is ever persisted,
            // even from a programmatic set (Codex P2). Re-entry settles after one pass.
            let valid = Self.normalizedColumns(columns)
            guard valid == columns else { columns = valid; return }
            storage.set(columns, forKey: Keys.columns)
        }
    }

    /// App ids (resolved absolute paths) the user has hidden from the grid.
    @Published private(set) var hiddenAppIDs: Set<String> {
        didSet { storage.set(Array(hiddenAppIDs), forKey: Keys.hidden) }
    }

    func hide(_ id: String) { hiddenAppIDs.insert(id) }
    func unhide(_ id: String) { hiddenAppIDs.remove(id) }
    func unhideAll() { hiddenAppIDs.removeAll() }

    @Published var hotCorner: HotCorner {
        didSet { storage.set(hotCorner.rawValue, forKey: Keys.hotCorner) }
    }

    // MARK: Appearance (design §3.1, features 7+8)

    /// Icon side in points. Single-write-path clamp + step alignment, same discipline
    /// as `columns` — no out-of-range or off-step value is ever persisted.
    @Published var iconSize: Int {
        didSet {
            let valid = Self.normalizedIconSize(iconSize)
            guard valid == iconSize else { iconSize = valid; return }
            storage.set(iconSize, forKey: Keys.iconSize)
        }
    }

    /// Negated key on purpose (design §3.1): `bool(forKey:)` returns false when unset,
    /// so an unset key means "names shown" — today's behaviour, zero migration.
    @Published var hidesAppNames: Bool {
        didSet { storage.set(hidesAppNames, forKey: Keys.hidesAppNames) }
    }

    /// Compact-panel scale in whole percent (PluginStorage has no double accessor).
    @Published var compactScalePercent: Int {
        didSet {
            let valid = Self.normalizedCompactScale(compactScalePercent)
            guard valid == compactScalePercent else { compactScalePercent = valid; return }
            storage.set(compactScalePercent, forKey: Keys.compactScalePercent)
        }
    }

    // MARK: Label appearance (design 2026-06-13)

    /// Label text colour preset. Default `.automatic` resolves to `.labelColor`, the
    /// historical implicit colour — zero migration. Persisted as the raw value (a String
    /// PluginStorage stores natively, no NSColor/Data encoding).
    @Published var labelColor: LaunchpadLabelColor {
        didSet { storage.set(labelColor.rawValue, forKey: Keys.labelColor) }
    }

    /// Label font-weight preset. Default `.regular` matches the historical system weight.
    @Published var labelWeight: LaunchpadLabelWeight {
        didSet { storage.set(labelWeight.rawValue, forKey: Keys.labelWeight) }
    }

    /// Label font-size tier. Default `.medium` derives 12pt at the 64pt icon — the byte-compat
    /// baseline; the other tiers scale with the icon side.
    @Published var labelSize: LaunchpadLabelSize {
        didSet { storage.set(labelSize.rawValue, forKey: Keys.labelSize) }
    }

    /// The single input to `LaunchpadGridMetrics.resolve(_:)` (and, later, the settings
    /// layout preview). Read-only derivation — features 7/8 own the writes above.
    /// The overlay snapshots the resolved metrics at `open()` (same session discipline
    /// as `windowMode`): appearance changes apply on the NEXT summon, never mid-session.
    var appearance: LaunchpadAppearance {
        LaunchpadAppearance(
            iconSide: CGFloat(Self.normalizedIconSize(iconSize)),
            showsLabels: !hidesAppNames,
            labelColor: labelColor,
            labelWeight: labelWeight,
            labelSize: labelSize
        )
    }

    // MARK: Glass background (design §5)

    @Published var backgroundStyle: LaunchpadBackgroundStyle {
        didSet { storage.set(backgroundStyle.rawValue, forKey: Keys.backgroundStyle) }
    }

    /// Only consulted while `backgroundStyle == .custom`; kept persisted across style
    /// switches so flipping back to custom restores the user's last tuning.
    @Published var backgroundMaterial: LaunchpadGlassMaterial {
        didSet { storage.set(backgroundMaterial.rawValue, forKey: Keys.backgroundMaterial) }
    }

    /// Custom-style dim layer, in whole percent (PluginStorage has no double accessor).
    @Published var backgroundDimPercent: Int {
        didSet {
            // Same single-write-path clamp discipline as `columns`.
            let valid = LaunchpadBackgroundDim.normalized(backgroundDimPercent)
            guard valid == backgroundDimPercent else { backgroundDimPercent = valid; return }
            storage.set(backgroundDimPercent, forKey: Keys.backgroundDimPercent)
        }
    }

    /// The full rendering description. The overlay snapshots it at `open()` (same session
    /// discipline as `windowMode`) — settings changes apply on the next summon.
    var backgroundRecipe: LaunchpadBackgroundRecipe {
        backgroundStyle.recipe(
            customMaterial: backgroundMaterial,
            customDimPercent: backgroundDimPercent
        )
    }

    private let storage: PluginStorage

    private enum Keys {
        static let windowMode = "windowMode"
        static let columns = "columns"
        static let hidden = "hiddenAppIDs"
        static let hotCorner = "hotCorner"
        static let iconSize = "iconSize"
        static let hidesAppNames = "hidesAppNames"
        static let compactScalePercent = "compactScalePercent"
        static let labelColor = "labelColor"
        static let labelWeight = "labelWeight"
        static let labelSize = "labelSize"
        static let backgroundStyle = "backgroundStyle"
        static let backgroundMaterial = "backgroundMaterial"
        static let backgroundDimPercent = "backgroundDimPercent"
    }

    static func normalizedColumns(_ value: Int) -> Int {
        value == autoColumns ? autoColumns : min(max(value, minColumns), maxColumns)
    }

    /// 0 (unset sentinel) → default; otherwise clamp to 48...96 and snap to the 4pt
    /// step (round-to-nearest, so a hand-edited 50 becomes 52, never an off-step size).
    static func normalizedIconSize(_ value: Int) -> Int {
        guard value != 0 else { return defaultIconSize }
        let clamped = min(max(value, minIconSize), maxIconSize)
        let snapped = minIconSize
            + ((clamped - minIconSize + iconSizeStep / 2) / iconSizeStep) * iconSizeStep
        return min(snapped, maxIconSize)
    }

    /// 0 (unset sentinel) → default 72; otherwise clamp to 55...90.
    static func normalizedCompactScale(_ value: Int) -> Int {
        guard value != 0 else { return defaultCompactScale }
        return min(max(value, minCompactScale), maxCompactScale)
    }

    init(storage: PluginStorage) {
        self.storage = storage
        self.windowMode = WindowMode(rawValue: storage.string(forKey: Keys.windowMode) ?? "")
            ?? .fullscreen
        // `integer(forKey:)` is 0 when unset → autoColumns, our default.
        self.columns = Self.normalizedColumns(storage.integer(forKey: Keys.columns))
        self.hiddenAppIDs = Set(storage.stringArray(forKey: Keys.hidden) ?? [])
        self.hotCorner = HotCorner(rawValue: storage.string(forKey: Keys.hotCorner) ?? "") ?? .off
        // 0-when-unset is safe as a sentinel here: both valid ranges start well above 0.
        self.iconSize = Self.normalizedIconSize(storage.integer(forKey: Keys.iconSize))
        self.hidesAppNames = storage.bool(forKey: Keys.hidesAppNames)
        self.compactScalePercent = Self.normalizedCompactScale(
            storage.integer(forKey: Keys.compactScalePercent))
        // Label-style presets: unknown/unset raw values fall back to the byte-compat defaults
        // (`.automatic`/`.regular`/`.medium`), same pattern as `windowMode`/`backgroundStyle`.
        self.labelColor = LaunchpadLabelColor(
            rawValue: storage.string(forKey: Keys.labelColor) ?? "") ?? .automatic
        self.labelWeight = LaunchpadLabelWeight(
            rawValue: storage.string(forKey: Keys.labelWeight) ?? "") ?? .regular
        self.labelSize = LaunchpadLabelSize(
            rawValue: storage.string(forKey: Keys.labelSize) ?? "") ?? .medium
        // Unknown raw values (a downgrade wrote a future style) fall back to the default,
        // same pattern as `windowMode`.
        self.backgroundStyle = LaunchpadBackgroundStyle(
            rawValue: storage.string(forKey: Keys.backgroundStyle) ?? ""
        ) ?? .standard
        self.backgroundMaterial = LaunchpadGlassMaterial(
            rawValue: storage.string(forKey: Keys.backgroundMaterial) ?? ""
        ) ?? .launchpad
        // `integer(forKey:)` returns 0 when unset, but 0 is a VALID dim — probe with
        // `object(forKey:)` so a stored 0 isn't mistaken for "use the default".
        self.backgroundDimPercent = storage.object(forKey: Keys.backgroundDimPercent) == nil
            ? LaunchpadBackgroundDim.defaultPercent
            : LaunchpadBackgroundDim.normalized(storage.integer(forKey: Keys.backgroundDimPercent))
    }
}
