import Foundation
import MacToolsPluginKit

// MARK: - ZshConfigFileType

/// Standard zsh configuration files in the user's home directory.
enum ZshConfigFileType: String, CaseIterable, Identifiable, Codable {
    case zshrc    = ".zshrc"
    case zshenv   = ".zshenv"
    case zprofile = ".zprofile"
    case zlogin   = ".zlogin"
    case zlogout  = ".zlogout"

    var id: String { rawValue }
    var filename: String { rawValue }

    /// One-sentence description of the file's role.
    var role: String {
        role()
    }

    func role(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .zshrc:
            return localization.string("file.zshrc.role", defaultValue: "交互式 Shell 配置：别名、函数、提示符等")
        case .zshenv:
            return localization.string("file.zshenv.role", defaultValue: "所有 Shell 的环境变量，最先被加载")
        case .zprofile:
            return localization.string("file.zprofile.role", defaultValue: "登录 Shell 初始化，早于 .zshrc")
        case .zlogin:
            return localization.string("file.zlogin.role", defaultValue: "登录 Shell 完成初始化后执行")
        case .zlogout:
            return localization.string("file.zlogout.role", defaultValue: "退出登录 Shell 时执行的清理脚本")
        }
    }

    /// Describes when zsh loads this file.
    var whenLoaded: String {
        whenLoaded()
    }

    func whenLoaded(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .zshrc:
            return localization.string("file.zshrc.whenLoaded", defaultValue: "每次打开新终端窗口/标签页时")
        case .zshenv:
            return localization.string("file.zshenv.whenLoaded", defaultValue: "每次启动 zsh（包括脚本、非交互式）时")
        case .zprofile:
            return localization.string("file.zprofile.whenLoaded", defaultValue: "登录时（SSH、macOS 登录等），早于 .zshrc")
        case .zlogin:
            return localization.string("file.zlogin.whenLoaded", defaultValue: "登录时，晚于 .zshrc")
        case .zlogout:
            return localization.string("file.zlogout.whenLoaded", defaultValue: "登录 Shell 退出时（`exit` 或关闭终端）")
        }
    }

    /// Recommended uses for this file.
    var recommendedUse: String {
        recommendedUse()
    }

    func recommendedUse(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .zshrc:
            return localization.string("file.zshrc.recommendedUse", defaultValue: "alias、函数、主题（Oh My Zsh / Starship 等）、PATH")
        case .zshenv:
            return localization.string("file.zshenv.recommendedUse", defaultValue: "EDITOR、LANG、必须对所有子进程可见的变量")
        case .zprofile:
            return localization.string("file.zprofile.recommendedUse", defaultValue: "Homebrew 的环境初始化、一次性登录脚本")
        case .zlogin:
            return localization.string("file.zlogin.recommendedUse", defaultValue: "欢迎信息、tmux 自动启动等")
        case .zlogout:
            return localization.string("file.zlogout.recommendedUse", defaultValue: "清理临时文件、记录会话日志")
        }
    }

    /// Absolute URL under the user's home directory.
    var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(rawValue)
    }
}

// MARK: - ZshFileStatus

/// Current status snapshot for a zsh configuration file.
struct ZshFileStatus {
    let type: ZshConfigFileType
    let exists: Bool
    let isWritable: Bool
    let byteSize: Int
    let modifiedDate: Date?

    var formattedSize: String {
        guard exists else { return "" }
        if byteSize < 1024 { return "\(byteSize) B" }
        return String(format: "%.1f KB", Double(byteSize) / 1024)
    }

    /// Probes the actual file status through FileManager.
    static func probe(_ type: ZshConfigFileType) -> ZshFileStatus {
        let url = type.fileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        let isWritable: Bool
        if exists {
            isWritable = fm.isWritableFile(atPath: url.path)
        } else {
            isWritable = fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
        }
        var byteSize = 0
        var modifiedDate: Date? = nil
        if exists,
           let attrs = try? fm.attributesOfItem(atPath: url.path) {
            byteSize = (attrs[.size] as? Int) ?? 0
            modifiedDate = attrs[.modificationDate] as? Date
        }
        return ZshFileStatus(
            type: type,
            exists: exists,
            isWritable: isWritable,
            byteSize: byteSize,
            modifiedDate: modifiedDate
        )
    }
}

// MARK: - ZshSnippet

/// Quick-insert snippet template.
struct ZshSnippet: Identifiable, Sendable {
    let id: String
    let icon: String
    let title: String
    let description: String
    let placeholder: String
    /// Builds the text to insert from user input.
    let buildContent: @Sendable (String) -> String

    static let all: [ZshSnippet] = localizedSnippets()

    static func localizedSnippets(
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> [ZshSnippet] {
        [
        ZshSnippet(
            id: "alias",
            icon: "arrow.uturn.right",
            title: localization.string("snippet.alias.title", defaultValue: "别名"),
            description: localization.string("snippet.alias.description", defaultValue: "为命令创建快捷方式"),
            placeholder: localization.string("snippet.alias.placeholder", defaultValue: "名称=命令，例：gs=git status"),
            buildContent: { input in
                let trimmed = input.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    return "alias \(parts[0].trimmingCharacters(in: .whitespaces))='\(parts[1].trimmingCharacters(in: .whitespaces))'"
                }
                return "alias \(trimmed)=''"
            }
        ),
        ZshSnippet(
            id: "export",
            icon: "square.and.arrow.up",
            title: localization.string("snippet.export.title", defaultValue: "环境变量"),
            description: localization.string("snippet.export.description", defaultValue: "设置或覆盖环境变量"),
            placeholder: localization.string("snippet.export.placeholder", defaultValue: "变量名=值，例：EDITOR=nvim"),
            buildContent: { input in
                let trimmed = input.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    return "export \(parts[0].trimmingCharacters(in: .whitespaces))=\(parts[1].trimmingCharacters(in: .whitespaces))"
                }
                return "export \(trimmed)="
            }
        ),
        ZshSnippet(
            id: "path",
            icon: "folder.badge.plus",
            title: localization.string("snippet.path.title", defaultValue: "PATH 路径"),
            description: localization.string("snippet.path.description", defaultValue: "将目录追加到 $PATH"),
            placeholder: localization.string("snippet.path.placeholder", defaultValue: "目录路径，例：/opt/homebrew/bin"),
            buildContent: { input in
                let path = input.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return "export PATH=\"$PATH:/your/path\"" }
                return "export PATH=\"$PATH:\(path)\""
            }
        ),
        ZshSnippet(
            id: "source",
            icon: "doc.badge.plus",
            title: localization.string("snippet.source.title", defaultValue: "加载文件"),
            description: localization.string("snippet.source.description", defaultValue: "在当前 Shell 中执行另一个脚本"),
            placeholder: localization.string("snippet.source.placeholder", defaultValue: "文件路径，例：~/.config/secrets.sh"),
            buildContent: { input in
                let path = input.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return "source ~/.your-script.sh" }
                return "source \(path)"
            }
        ),
        ZshSnippet(
            id: "function",
            icon: "f.cursive",
            title: localization.string("snippet.function.title", defaultValue: "函数"),
            description: localization.string("snippet.function.description", defaultValue: "定义一个可复用的 Shell 函数"),
            placeholder: localization.string("snippet.function.placeholder", defaultValue: "函数名称，例：mkcd"),
            buildContent: { input in
                let name = input.trimmingCharacters(in: .whitespaces)
                let funcName = name.isEmpty ? "my_func" : name
                let comment = localization.string("snippet.function.bodyComment", defaultValue: "在此填写函数内容")
                return "\(funcName)() {\n  # \(comment)\n  \n}"
            }
        ),
        ZshSnippet(
            id: "eval",
            icon: "terminal",
            title: localization.string("snippet.eval.title", defaultValue: "初始化工具"),
            description: localization.string("snippet.eval.description", defaultValue: "执行工具的 eval 初始化命令"),
            placeholder: localization.string("snippet.eval.placeholder", defaultValue: "工具命令，例：$(brew shellenv)"),
            buildContent: { input in
                let cmd = input.trimmingCharacters(in: .whitespaces)
                guard !cmd.isEmpty else { return "eval \"$(your-tool init zsh)\"" }
                if cmd.hasPrefix("$(") || cmd.hasPrefix("`") {
                    return "eval \"\(cmd)\""
                }
                return "eval \"$(\(cmd))\""
            }
        ),
        ]
    }
}
