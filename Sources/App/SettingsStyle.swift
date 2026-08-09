import SwiftUI
import MacToolsPluginKit

enum SettingsStyle {
    static var windowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var contentBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var recessedControlBackground: Color {
        PluginSettingsTheme.Palette.recessedControlBackground
    }

    static var fieldBackground: Color {
        PluginSettingsTheme.Palette.fieldBackground
    }

    static var keycapBackground: Color {
        PluginSettingsTheme.Palette.keycapBackground
    }

    static var separator: Color {
        PluginSettingsTheme.Palette.separator
    }

    static var cardBorder: Color {
        PluginSettingsTheme.Palette.cardBorder
    }

    static var activeControlBackground: Color {
        PluginSettingsTheme.Palette.activeControlBackground
    }

    static var recordingBackground: Color {
        PluginSettingsTheme.Palette.recordingBackground
    }
}
