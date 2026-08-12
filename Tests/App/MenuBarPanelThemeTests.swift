import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class MenuBarPanelThemeImporterTests: XCTestCase {
    func testBuiltInThemesHaveCompleteAccessiblePalettes() throws {
        XCTAssertEqual(MenuBarPanelBuiltInThemes.all.count, 14)
        XCTAssertEqual(Set(MenuBarPanelBuiltInThemes.all.map(\.id)).count, 14)

        for theme in MenuBarPanelBuiltInThemes.all {
            for index in 0...0x0F {
                XCTAssertNotNil(
                    theme.color(String(format: "base%02X", index)),
                    "\(theme.name) is missing base\(String(format: "%02X", index))"
                )
            }

            let background = try XCTUnwrap(theme.color("base00"))
            let foreground = try XCTUnwrap(theme.color("base05"))
            XCTAssertGreaterThanOrEqual(
                foreground.contrastRatio(with: background),
                4.5,
                "\(theme.name) must provide accessible body text"
            )
        }

        XCTAssertEqual(MenuBarPanelBuiltInThemes.all.filter { $0.appearance == .light }.count, 7)
        XCTAssertEqual(MenuBarPanelBuiltInThemes.all.filter { $0.appearance == .dark }.count, 7)
        XCTAssertTrue(MenuBarPanelBuiltInThemes.all.prefix(7).allSatisfy { $0.appearance == .light })
        XCTAssertTrue(MenuBarPanelBuiltInThemes.all.suffix(7).allSatisfy { $0.appearance == .dark })
        XCTAssertTrue(MenuBarPanelBuiltInThemes.all.contains { $0.name == "VS Code Light Modern" })
        XCTAssertTrue(MenuBarPanelBuiltInThemes.all.contains { $0.name == "VS Code Dark Modern" })
    }

    func testDecodesClassicBase16YAML() throws {
        let theme = try MenuBarPanelThemeImporter.decode(data: Data(base16YAML.utf8))

        XCTAssertEqual(theme.name, "Test Dark")
        XCTAssertEqual(theme.author, "MacTools")
        XCTAssertEqual(theme.appearance, .dark)
        XCTAssertEqual(theme.color("base0D")?.hex, "#61AFEF")
        XCTAssertFalse(theme.isBase24)
    }

    func testBuiltInResolvedUITokensKeepTextAndFunctionalContrast() throws {
        for definition in MenuBarPanelBuiltInThemes.all {
            let colorScheme = MenuBarPanelThemeResolver.colorScheme(for: definition.appearance)
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let style = MenuBarPanelThemeResolver.resolve(
                    definition: definition,
                    colorScheme: colorScheme,
                    contrast: contrast
                )
                let primary = try rgb(style.text.primary)
                let secondary = try rgb(style.text.secondary)
                let tertiary = try rgb(style.text.tertiary)
                let textSurfaces = try [
                    style.surfaces.panel,
                    style.surfaces.card,
                    style.surfaces.nested,
                    style.surfaces.nestedMuted,
                    style.surfaces.control,
                    style.surfaces.hover,
                    style.surfaces.navigationHover,
                    style.surfaces.selected
                ].map(rgb)
                let primaryTextTarget = contrast == .increased ? 6.98 : 4.48
                let secondaryTextTarget = 4.48
                let tertiaryTextTarget = contrast == .increased ? 4.48 : 2.98
                let functionalTarget = contrast == .increased ? 4.48 : 2.98

                for surface in textSurfaces {
                    XCTAssertGreaterThanOrEqual(
                        primary.contrastRatio(with: surface),
                        primaryTextTarget,
                        "\(definition.name) primary text lost \(contrast) contrast"
                    )
                    XCTAssertGreaterThanOrEqual(
                        secondary.contrastRatio(with: surface),
                        secondaryTextTarget,
                        "\(definition.name) secondary text lost \(contrast) contrast"
                    )
                    XCTAssertGreaterThanOrEqual(
                        tertiary.contrastRatio(with: surface),
                        tertiaryTextTarget,
                        "\(definition.name) tertiary text lost \(contrast) contrast"
                    )
                }

                let tabSelection = try rgb(style.surfaces.tabSelection)
                XCTAssertGreaterThanOrEqual(
                    primary.contrastRatio(with: tabSelection),
                    primaryTextTarget,
                    "\(definition.name) selected tab icon lost \(contrast) contrast"
                )

                let functionalColors = try [
                    style.accent,
                    style.status.success,
                    style.status.warning,
                    style.status.critical,
                    style.status.informational,
                    style.componentTheme.dataSeries.primary,
                    style.componentTheme.dataSeries.secondary,
                    style.componentTheme.dataSeries.tertiary,
                    style.componentTheme.dataSeries.quaternary,
                    style.componentTheme.dataSeries.quinary,
                    style.componentTheme.dataSeries.senary
                ].map(rgb)
                for color in functionalColors {
                    for surface in textSurfaces.prefix(2) {
                        XCTAssertGreaterThanOrEqual(
                            color.contrastRatio(with: surface),
                            functionalTarget,
                            "\(definition.name) functional color lost \(contrast) contrast"
                        )
                    }
                }

                let prominentFill = try rgb(style.prominentControlFill)
                let prominentLabel = try rgb(style.text.onAccent)
                XCTAssertGreaterThanOrEqual(
                    prominentFill.contrastRatio(with: prominentLabel),
                    4.48,
                    "\(definition.name) prominent button label lost contrast"
                )
            }
        }
    }

    func testIncreasedContrastMakesCustomCardSurfaceMoreDistinct() throws {
        for definition in MenuBarPanelBuiltInThemes.all {
            let colorScheme = MenuBarPanelThemeResolver.colorScheme(for: definition.appearance)
            let standard = MenuBarPanelThemeResolver.resolve(
                definition: definition,
                colorScheme: colorScheme,
                contrast: .standard
            )
            let increased = MenuBarPanelThemeResolver.resolve(
                definition: definition,
                colorScheme: colorScheme,
                contrast: .increased
            )
            let standardContrast = try rgb(standard.surfaces.panel)
                .contrastRatio(with: rgb(standard.surfaces.card))
            let increasedContrast = try rgb(increased.surfaces.panel)
                .contrastRatio(with: rgb(increased.surfaces.card))

            XCTAssertGreaterThan(
                increasedContrast,
                standardContrast,
                "\(definition.name) card did not respond to Increase Contrast"
            )
        }
    }

    func testDecodesNestedBase24JSONAndPreservesExtendedColors() throws {
        var palette: [String: String] = [:]
        for index in 0...0x17 {
            palette[String(format: "base%02X", index)] = "#778899"
        }
        palette["base00"] = "#101216"
        palette["base05"] = "#E6E8EB"
        palette["base17"] = "#FFAA77"

        let data = try JSONSerialization.data(withJSONObject: [
            "name": "Extended Dark",
            "author": "MacTools",
            "palette": palette
        ])
        let theme = try MenuBarPanelThemeImporter.decode(data: data)

        XCTAssertTrue(theme.isBase24)
        XCTAssertEqual(theme.color("base17")?.hex, "#FFAA77")
        XCTAssertEqual(theme.appearance, .dark)
    }

    func testRejectsThemeWhoseBodyTextDoesNotMeetMinimumContrast() {
        let source = base16YAML.replacingOccurrences(of: "base05: \"ABB2BF\"", with: "base05: \"30343B\"")

        XCTAssertThrowsError(try MenuBarPanelThemeImporter.decode(data: Data(source.utf8))) { error in
            guard case let MenuBarPanelThemeImportError.insufficientForegroundContrast(ratio) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertLessThan(ratio, 4.5)
        }
    }

    private var base16YAML: String {
        """
        scheme: "Test Dark"
        author: "MacTools"
        base00: "282C34"
        base01: "353B45"
        base02: "3E4451"
        base03: "545862"
        base04: "565C64"
        base05: "ABB2BF"
        base06: "B6BDCA"
        base07: "C8CCD4"
        base08: "E06C75"
        base09: "D19A66"
        base0A: "E5C07B"
        base0B: "98C379"
        base0C: "56B6C2"
        base0D: "61AFEF"
        base0E: "C678DD"
        base0F: "BE5046"
        """
    }

    private func rgb(_ color: Color) throws -> MenuBarPanelThemeColor {
        let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return MenuBarPanelThemeColor(
            red: UInt8((resolved.redComponent * 255).rounded()),
            green: UInt8((resolved.greenComponent * 255).rounded()),
            blue: UInt8((resolved.blueComponent * 255).rounded())
        )
    }
}

@MainActor
final class MenuBarPanelThemeStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MenuBarPanelThemeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPersistsIndependentLightAndDarkSelections() throws {
        let lightTheme = try XCTUnwrap(
            MenuBarPanelBuiltInThemes.all.first { $0.appearance == .light }
        )
        let darkTheme = try XCTUnwrap(
            MenuBarPanelBuiltInThemes.all.first { $0.appearance == .dark }
        )
        let store = MenuBarPanelThemeStore(userDefaults: defaults)

        XCTAssertTrue(store.selectTheme(id: lightTheme.id, for: .light))
        XCTAssertTrue(store.selectTheme(id: darkTheme.id, for: .dark))

        let restoredStore = MenuBarPanelThemeStore(userDefaults: defaults)
        XCTAssertEqual(restoredStore.lightThemeID, lightTheme.id)
        XCTAssertEqual(restoredStore.darkThemeID, darkTheme.id)
        XCTAssertEqual(restoredStore.selectedDefinition(for: .light), lightTheme)
        XCTAssertEqual(restoredStore.selectedDefinition(for: .dark), darkTheme)
    }

    func testRepairsSelectionThatDoesNotMatchAppearance() throws {
        let darkTheme = try XCTUnwrap(
            MenuBarPanelBuiltInThemes.all.first { $0.appearance == .dark }
        )
        defaults.set(darkTheme.id, forKey: MenuBarPanelThemeStore.lightThemeKey)

        let store = MenuBarPanelThemeStore(userDefaults: defaults)

        XCTAssertEqual(store.lightThemeID, MenuBarPanelThemeDefinition.systemThemeID)
        XCTAssertNil(store.selectedDefinition(for: .light))
    }
}

final class MenuBarPanelThemePickerRoutingTests: XCTestCase {
    func testEachPresentationCarriesRequestedAppearanceWithFreshIdentity() {
        let light = MenuBarPanelThemePickerPresentation(appearance: .light)
        let dark = MenuBarPanelThemePickerPresentation(appearance: .dark)

        XCTAssertEqual(light.appearance, .light)
        XCTAssertEqual(dark.appearance, .dark)
        XCTAssertNotEqual(light.id, dark.id)
    }

    func testSystemAppearanceUsesCurrentColorScheme() {
        XCTAssertEqual(
            MenuBarPanelThemePickerRouting.preferredAppearance(for: .system, colorScheme: .light),
            .light
        )
        XCTAssertEqual(
            MenuBarPanelThemePickerRouting.preferredAppearance(for: .system, colorScheme: .dark),
            .dark
        )
    }

    func testExplicitAppearanceOverridesCurrentColorScheme() {
        XCTAssertEqual(
            MenuBarPanelThemePickerRouting.preferredAppearance(for: .light, colorScheme: .dark),
            .light
        )
        XCTAssertEqual(
            MenuBarPanelThemePickerRouting.preferredAppearance(for: .dark, colorScheme: .light),
            .dark
        )
    }
}
