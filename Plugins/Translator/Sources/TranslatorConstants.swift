import Carbon
import Foundation
import MacToolsPluginKit

enum TranslatorConstants {
    static let pluginID = "translator"

    enum PermissionID {
        static let accessibility = "accessibility"
        static let automation = "automation"
        static let screenRecording = "screen-recording"
    }

    enum ShortcutID {
        static let selectTranslation = "translator.select-translation"
        static let screenshotTranslation = "translator.screenshot-translation"
    }

    enum ActionID {
        static let selectTranslation = "select-translation"
        static let screenshotTranslation = "screenshot-translation"
    }

    enum StorageKey {
        static let shortcutEnabled = "translator.shortcut.enabled"
        static let providerProfiles = "translator.providers.profiles"
        static let openAIBaseURL = "translator.openai.base-url"
        static let openAIModel = "translator.openai.model"
        static let openAIPromptTemplate = "translator.openai.prompt-template"
        static let firstPreferredLanguage = "translator.language.first"
        static let secondPreferredLanguage = "translator.language.second"
    }

    enum Defaults {
        static let shortcutEnabled = true
        static let selectTranslationShortcut = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_D),
            modifiers: [.option]
        )
        static let screenshotTranslationShortcut = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_S),
            modifiers: [.option]
        )
    }
}
