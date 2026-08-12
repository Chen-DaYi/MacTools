import AppKit
import SwiftUI
import MacToolsPluginKit

struct MenuBarPanelThemeStyle: Sendable {
    struct Surfaces: Sendable {
        let panel: Color
        let card: Color
        let nested: Color
        let nestedMuted: Color
        let control: Color
        let hover: Color
        let navigationHover: Color
        let selected: Color
        let tabSelection: Color
        let separator: Color
        let track: Color
        let backplate: Color
    }

    struct Text: Sendable {
        let primary: Color
        let secondary: Color
        let tertiary: Color
        let disabled: Color
        let onAccent: Color
    }

    struct Status: Sendable {
        let success: Color
        let warning: Color
        let critical: Color
        let informational: Color
    }

    let id: String
    let name: String
    let isSystemDefault: Bool
    let surfaces: Surfaces
    let text: Text
    let accent: Color
    let prominentControlFill: Color
    let status: Status
    let componentTheme: PluginComponentTheme
}

enum MenuBarPanelThemeResolver {
    static func resolve(
        definition: MenuBarPanelThemeDefinition?,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> MenuBarPanelThemeStyle {
        guard let definition else {
            return system(colorScheme: colorScheme, contrast: contrast)
        }
        return custom(definition, colorScheme: colorScheme, contrast: contrast)
    }

    static func appearance(for colorScheme: ColorScheme) -> MenuBarPanelThemeAppearance {
        colorScheme == .dark ? .dark : .light
    }

    static func colorScheme(for appearance: MenuBarPanelThemeAppearance) -> ColorScheme {
        appearance == .dark ? .dark : .light
    }

    private static func system(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> MenuBarPanelThemeStyle {
        let componentTheme = PluginComponentTheme.system(
            colorScheme: colorScheme,
            contrast: contrast
        )
        let adaptiveTint = colorScheme == .dark ? Color.white : Color.black
        let increased = contrast == .increased

        return MenuBarPanelThemeStyle(
            id: MenuBarPanelThemeDefinition.systemThemeID,
            name: AppL10n.settings("panelTheme.systemDefault", defaultValue: "系统默认"),
            isSystemDefault: true,
            surfaces: MenuBarPanelThemeStyle.Surfaces(
                panel: Color(nsColor: .windowBackgroundColor),
                card: componentTheme.surfaces.card,
                nested: componentTheme.surfaces.nested,
                nestedMuted: componentTheme.surfaces.nestedMuted,
                control: componentTheme.surfaces.control,
                hover: adaptiveTint.opacity(increased ? 0.10 : 0.06),
                navigationHover: adaptiveTint.opacity(increased ? 0.15 : 0.10),
                selected: adaptiveTint.opacity(increased ? 0.19 : 0.13),
                tabSelection: adaptiveTint.opacity(increased ? 0.19 : 0.13),
                separator: Color(nsColor: .separatorColor),
                track: componentTheme.surfaces.track,
                backplate: componentTheme.surfaces.backplate
            ),
            text: MenuBarPanelThemeStyle.Text(
                primary: componentTheme.text.primary,
                secondary: componentTheme.text.secondary,
                tertiary: componentTheme.text.tertiary,
                disabled: componentTheme.text.disabled,
                onAccent: .white
            ),
            accent: Color(nsColor: .controlAccentColor),
            prominentControlFill: Color(nsColor: .controlAccentColor),
            status: MenuBarPanelThemeStyle.Status(
                success: componentTheme.status.success,
                warning: componentTheme.status.warning,
                critical: componentTheme.status.critical,
                informational: componentTheme.status.informational
            ),
            componentTheme: componentTheme
        )
    }

    private static func custom(
        _ definition: MenuBarPanelThemeDefinition,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> MenuBarPanelThemeStyle {
        func required(_ key: String) -> MenuBarPanelThemeColor {
            definition.color(key) ?? MenuBarPanelThemeColor(red: 0, green: 0, blue: 0)
        }

        let base00 = required("base00")
        let base01 = required("base01")
        let base02 = required("base02")
        let base03 = required("base03")
        let base04 = required("base04")
        let base05 = required("base05")
        let base07 = required("base07")
        let increased = contrast == .increased
        let card = increased
            ? base01.mixed(
                with: colorScheme == .dark ? .white : .black,
                amount: 0.08
            )
            : base01
        let primaryTextContrastTarget = increased ? 7.0 : 4.5
        let functionalContrastTarget = increased ? 4.5 : 3.0

        let nested = card.mixed(with: base02, amount: increased ? 0.58 : 0.42)
        let nestedMuted = base00.mixed(with: card, amount: increased ? 0.72 : 0.52)
        let rawControl = card.mixed(with: base02, amount: increased ? 0.72 : 0.55)
        let rawHover = card.mixed(with: base02, amount: increased ? 0.76 : 0.58)
        let rawNavigationHover = card.mixed(with: base02, amount: increased ? 0.88 : 0.76)
        let separator = base00.mixed(with: base03, amount: increased ? 0.76 : 0.55)
        let primary = functionalColor(
            base05,
            contrastTarget: primaryTextContrastTarget,
            backgrounds: [base00, card, nested, nestedMuted],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        // Base16 defines base02 as a selection color, but terminal palettes are not
        // necessarily authored for small UI text. Keep each interactive surface as
        // close to that source color as its body-text contrast allows.
        let control = accessibleSurface(
            rawControl,
            from: card,
            foreground: primary,
            minimumContrast: primaryTextContrastTarget
        )
        let hover = accessibleSurface(
            rawHover,
            from: card,
            foreground: primary,
            minimumContrast: primaryTextContrastTarget
        )
        let navigationHover = accessibleSurface(
            rawNavigationHover,
            from: card,
            foreground: primary,
            minimumContrast: primaryTextContrastTarget
        )
        let selected = accessibleSurface(
            base02,
            from: card,
            foreground: primary,
            minimumContrast: primaryTextContrastTarget
        )
        let textSurfaces = [
            base00,
            card,
            nested,
            nestedMuted,
            control,
            hover,
            navigationHover,
            selected
        ]
        let secondary = base04.adjusted(
            toward: primary,
            minimumContrast: 4.5,
            against: textSurfaces
        )
        let tertiary = base03.adjusted(
            toward: secondary,
            minimumContrast: increased ? 4.5 : 3.0,
            against: textSurfaces
        )

        let accent = functionalColor(
            required("base0D"),
            contrastTarget: functionalContrastTarget,
            backgrounds: [base00, card],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        let success = functionalColor(
            required("base0B"),
            contrastTarget: functionalContrastTarget,
            backgrounds: [base00, card],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        let warning = functionalColor(
            required("base09"),
            contrastTarget: functionalContrastTarget,
            backgrounds: [base00, card],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        let critical = functionalColor(
            required("base08"),
            contrastTarget: functionalContrastTarget,
            backgrounds: [base00, card],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        let informational = functionalColor(
            required("base0C"),
            contrastTarget: functionalContrastTarget,
            backgrounds: [base00, card],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        let quaternary = functionalColor(
            required("base0E"),
            contrastTarget: functionalContrastTarget,
            backgrounds: [base00, card],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        let senary = functionalColor(
            required("base0A"),
            contrastTarget: functionalContrastTarget,
            backgrounds: [base00, card],
            darkEndpoint: base07,
            lightEndpoint: base00
        )
        let tabSelection = accessibleSurface(
            card.mixed(with: accent, amount: increased ? 0.30 : 0.22),
            from: card,
            foreground: primary,
            minimumContrast: primaryTextContrastTarget
        )
        let prominentControlFill = accent.adjusted(
            toward: .black,
            minimumContrast: 4.5,
            against: [.white]
        )

        let selectionOpacity = colorScheme == .dark
            ? (increased ? 0.24 : 0.18)
            : (increased ? 0.22 : 0.16)
        let emphasisOpacity = colorScheme == .dark
            ? (increased ? 0.15 : 0.10)
            : (increased ? 0.12 : 0.08)
        let componentTheme = PluginComponentTheme(
            surfaces: PluginComponentTheme.SurfacePalette(
                panel: base00.swiftUIColor,
                card: card.swiftUIColor,
                nested: nested.swiftUIColor,
                nestedMuted: nestedMuted.swiftUIColor,
                chip: control.swiftUIColor,
                control: control.swiftUIColor,
                controlHover: navigationHover.swiftUIColor,
                track: separator.swiftUIColor,
                backplate: card.swiftUIColor
            ),
            text: PluginComponentTheme.TextPalette(
                primary: primary.swiftUIColor,
                secondary: secondary.swiftUIColor,
                tertiary: tertiary.swiftUIColor,
                disabled: tertiary.swiftUIColor
            ),
            status: PluginComponentTheme.StatusPalette(
                success: success.swiftUIColor,
                warning: warning.swiftUIColor,
                critical: critical.swiftUIColor,
                informational: informational.swiftUIColor
            ),
            dataSeries: PluginComponentTheme.DataSeriesPalette(
                primary: accent.swiftUIColor,
                secondary: warning.swiftUIColor,
                tertiary: success.swiftUIColor,
                quaternary: quaternary.swiftUIColor,
                quinary: informational.swiftUIColor,
                senary: senary.swiftUIColor
            ),
            interaction: PluginComponentTheme.InteractionPalette(
                selectionOpacity: selectionOpacity,
                emphasisOpacity: emphasisOpacity,
                subtleTintOpacity: emphasisOpacity
            )
        )

        return MenuBarPanelThemeStyle(
            id: definition.id,
            name: definition.name,
            isSystemDefault: false,
            surfaces: MenuBarPanelThemeStyle.Surfaces(
                panel: base00.swiftUIColor,
                card: card.swiftUIColor,
                nested: nested.swiftUIColor,
                nestedMuted: nestedMuted.swiftUIColor,
                control: control.swiftUIColor,
                hover: hover.swiftUIColor,
                navigationHover: navigationHover.swiftUIColor,
                selected: selected.swiftUIColor,
                tabSelection: tabSelection.swiftUIColor,
                separator: separator.swiftUIColor,
                track: separator.swiftUIColor,
                backplate: card.swiftUIColor
            ),
            text: MenuBarPanelThemeStyle.Text(
                primary: primary.swiftUIColor,
                secondary: secondary.swiftUIColor,
                tertiary: tertiary.swiftUIColor,
                disabled: tertiary.swiftUIColor,
                onAccent: .white
            ),
            accent: accent.swiftUIColor,
            prominentControlFill: prominentControlFill.swiftUIColor,
            status: MenuBarPanelThemeStyle.Status(
                success: success.swiftUIColor,
                warning: warning.swiftUIColor,
                critical: critical.swiftUIColor,
                informational: informational.swiftUIColor
            ),
            componentTheme: componentTheme
        )
    }

    private static func functionalColor(
        _ color: MenuBarPanelThemeColor,
        contrastTarget: Double,
        backgrounds: [MenuBarPanelThemeColor],
        darkEndpoint: MenuBarPanelThemeColor,
        lightEndpoint: MenuBarPanelThemeColor
    ) -> MenuBarPanelThemeColor {
        if backgrounds.allSatisfy({ color.contrastRatio(with: $0) >= contrastTarget }) {
            return color
        }

        let candidates = [darkEndpoint, lightEndpoint, .black, .white].map { endpoint in
            color.adjusted(
                toward: endpoint,
                minimumContrast: contrastTarget,
                against: backgrounds
            )
        }
        return candidates.max { lhs, rhs in
            let lhsMinimum = backgrounds.map { lhs.contrastRatio(with: $0) }.min() ?? 0
            let rhsMinimum = backgrounds.map { rhs.contrastRatio(with: $0) }.min() ?? 0
            return lhsMinimum < rhsMinimum
        } ?? color
    }

    private static func accessibleSurface(
        _ target: MenuBarPanelThemeColor,
        from source: MenuBarPanelThemeColor,
        foreground: MenuBarPanelThemeColor,
        minimumContrast: Double
    ) -> MenuBarPanelThemeColor {
        guard foreground.contrastRatio(with: target) < minimumContrast else {
            return target
        }
        guard foreground.contrastRatio(with: source) >= minimumContrast else {
            return source
        }

        var lowerBound = 0.0
        var upperBound = 1.0
        for _ in 0..<14 {
            let amount = (lowerBound + upperBound) / 2
            let candidate = source.mixed(with: target, amount: amount)
            if foreground.contrastRatio(with: candidate) >= minimumContrast {
                lowerBound = amount
            } else {
                upperBound = amount
            }
        }
        return source.mixed(with: target, amount: lowerBound)
    }

}

private struct MenuBarPanelThemeStyleEnvironmentKey: EnvironmentKey {
    static let defaultValue = MenuBarPanelThemeResolver.resolve(
        definition: nil,
        colorScheme: .light,
        contrast: .standard
    )
}

extension EnvironmentValues {
    var menuBarPanelTheme: MenuBarPanelThemeStyle {
        get { self[MenuBarPanelThemeStyleEnvironmentKey.self] }
        set { self[MenuBarPanelThemeStyleEnvironmentKey.self] = newValue }
    }
}

extension MenuBarPanelThemeColor {
    static let black = MenuBarPanelThemeColor(red: 0, green: 0, blue: 0)
    static let white = MenuBarPanelThemeColor(red: 255, green: 255, blue: 255)

    var swiftUIColor: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

struct MenuBarPanelBackground: View {
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        theme.surfaces.panel
    }
}
