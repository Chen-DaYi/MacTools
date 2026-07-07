import Foundation

private final class PluginKitBundleToken {}

public enum PluginKitLocalization {
    public static var defaultShortcutPlaceholder: String {
        string("shortcutRecorder.defaultPlaceholder", defaultValue: "未设置")
    }

    static var shortcutRecorderPreviewPlaceholder: String {
        string("shortcutRecorder.previewPlaceholder", defaultValue: "按下录制快捷键")
    }

    static var shortcutRecorderEscHint: String {
        string("shortcutRecorder.escHint", defaultValue: "按下 ESC 退出录制")
    }

    static var shortcutValidationMissingModifier: String {
        string("shortcutValidation.missingModifier", defaultValue: "快捷键至少需要一个修饰键。")
    }

    static var shortcutValidationModifierOnly: String {
        string("shortcutValidation.modifierOnly", defaultValue: "快捷键必须包含一个非修饰键。")
    }

    static var shortcutValidationRequiredShortcut: String {
        string("shortcutValidation.requiredShortcut", defaultValue: "该快捷键不能为空。")
    }

    static func shortcutValidationDuplicate(ownerDescription: String) -> String {
        String(
            format: string("shortcutValidation.duplicateFormat", defaultValue: "该快捷键已被“%@”占用。"),
            ownerDescription
        )
    }

    static func shortcutRecorderHelp(title: String) -> String {
        String(
            format: string("shortcutRecorder.helpFormat", defaultValue: "点击录制%@"),
            title
        )
    }

    static func string(_ key: String, defaultValue: String) -> String {
        Bundle(for: PluginKitBundleToken.self).localizedString(
            forKey: key,
            value: defaultValue,
            table: nil
        )
    }
}
