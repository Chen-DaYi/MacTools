import Foundation

private final class PluginKitBundleToken {}

public enum PluginKitLocalization {
    public static var actionInvalidParameters: String {
        string("action.error.invalidParameters", defaultValue: "操作参数无效。")
    }

    public static var actionUnavailable: String {
        string("action.error.unavailable", defaultValue: "操作不可用。")
    }

    public static var actionFailed: String {
        string("action.error.failed", defaultValue: "操作未能完成。")
    }

    public static var defaultShortcutPlaceholder: String {
        string("shortcutRecorder.defaultPlaceholder", defaultValue: "未设置")
    }

    public static var keyboardKeyLeft: String {
        string("keyboardKey.side.left", defaultValue: "左侧")
    }

    public static var keyboardKeyRight: String {
        string("keyboardKey.side.right", defaultValue: "右侧")
    }

    public static var keyboardKeyTapPrompt: String {
        string("keyboardKeyTap.prompt", defaultValue: "按下一个按键")
    }

    public static var keyboardKeyTapUnset: String {
        string("keyboardKeyTap.unset", defaultValue: "未设置")
    }

    public static var keyboardKeyTapUnsupportedHelp: String {
        string(
            "keyboardKeyTap.unsupportedHelp",
            defaultValue: "不支持大写锁定和媒体键。"
        )
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
            locale: PluginRuntimeLocalization.locale,
            arguments: [ownerDescription]
        )
    }

    static func shortcutRecorderHelp(title: String) -> String {
        String(
            format: string("shortcutRecorder.helpFormat", defaultValue: "点击录制%@"),
            locale: PluginRuntimeLocalization.locale,
            arguments: [title]
        )
    }

    static func string(_ key: String, defaultValue: String) -> String {
        PluginRuntimeLocalization.string(
            key,
            defaultValue: defaultValue,
            bundle: Bundle(for: PluginKitBundleToken.self)
        )
    }
}
