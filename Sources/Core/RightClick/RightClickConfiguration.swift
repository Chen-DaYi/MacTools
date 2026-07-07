import Foundation

/// Shared state for the MacTools Finder right-click menu.
///
/// The host app writes both user preferences and the lightweight lifecycle gate
/// (`menuEnabled`). The sandboxed extension reads the same file to decide
/// whether to show anything, then which items to include.
///
/// This type is compiled into BOTH the host app and the extension targets (they
/// can't import each other); the JSON written by one is decoded by the other.
struct RightClickConfiguration: Codable, Equatable {
    var menuEnabled: Bool
    var preferredLanguages: [String]?
    var newFolder: Bool
    var copyFileName: Bool
    var copyAbsolutePath: Bool
    var copyRelativePath: Bool
    var copyShellEscapedPath: Bool
    var copyFileURL: Bool
    var newFile: Bool
    var openInTerminal: Bool
    var openWithApps: [RightClickOpenWithApp]

    init(
        menuEnabled: Bool = false,
        preferredLanguages: [String]? = nil,
        newFolder: Bool = true,
        copyFileName: Bool = true,
        copyAbsolutePath: Bool = true,
        copyRelativePath: Bool = true,
        copyShellEscapedPath: Bool = true,
        copyFileURL: Bool = true,
        newFile: Bool = true,
        openInTerminal: Bool = true,
        openWithApps: [RightClickOpenWithApp] = []
    ) {
        self.menuEnabled = menuEnabled
        self.preferredLanguages = preferredLanguages
        self.newFolder = newFolder
        self.copyFileName = copyFileName
        self.copyAbsolutePath = copyAbsolutePath
        self.copyRelativePath = copyRelativePath
        self.copyShellEscapedPath = copyShellEscapedPath
        self.copyFileURL = copyFileURL
        self.newFile = newFile
        self.openInTerminal = openInTerminal
        self.openWithApps = openWithApps
    }

    /// Used when the shared file is missing or unreadable. The extension should
    /// stay silent until the host plugin explicitly activates and writes state.
    static let inactiveDefault = RightClickConfiguration(menuEnabled: false)

    /// Menu defaults used once the host plugin is active.
    static let activeDefault = RightClickConfiguration(menuEnabled: true)

    static let `default` = inactiveDefault

    /// True when at least one copy action is enabled (used to skip the section).
    var hasAnyCopyAction: Bool {
        copyFileName || copyAbsolutePath || copyRelativePath || copyShellEscapedPath || copyFileURL
    }

    /// Decode tolerantly: keys added after a config was first written fall back
    /// to their defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RightClickConfiguration.activeDefault
        func flag(_ key: CodingKeys, _ defaultValue: Bool) -> Bool {
            (try? container.decode(Bool.self, forKey: key)) ?? defaultValue
        }
        menuEnabled = flag(.menuEnabled, fallback.menuEnabled)
        preferredLanguages = try? container.decodeIfPresent([String].self, forKey: .preferredLanguages)
        newFolder = flag(.newFolder, fallback.newFolder)
        copyFileName = flag(.copyFileName, fallback.copyFileName)
        copyAbsolutePath = flag(.copyAbsolutePath, fallback.copyAbsolutePath)
        copyRelativePath = flag(.copyRelativePath, fallback.copyRelativePath)
        copyShellEscapedPath = flag(.copyShellEscapedPath, fallback.copyShellEscapedPath)
        copyFileURL = flag(.copyFileURL, fallback.copyFileURL)
        newFile = flag(.newFile, fallback.newFile)
        openInTerminal = flag(.openInTerminal, fallback.openInTerminal)
        openWithApps = (try? container.decode([RightClickOpenWithApp].self, forKey: .openWithApps)) ?? []
    }
}

/// A user-configured "open with" application entry.
struct RightClickOpenWithApp: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var appPath: String
    /// Lowercased file extensions this entry applies to; empty = all files.
    var fileExtensions: [String]

    init(id: UUID = UUID(), name: String, appPath: String, fileExtensions: [String] = []) {
        self.id = id
        self.name = name
        self.appPath = appPath
        self.fileExtensions = fileExtensions
    }

    /// Whether this entry should appear for a file with the given (lowercased)
    /// extension. An empty `fileExtensions` matches everything.
    func matches(fileExtension ext: String) -> Bool {
        fileExtensions.isEmpty || fileExtensions.contains(ext.lowercased())
    }
}

/// Reads/writes `RightClickConfiguration` via a JSON file under the user's real
/// home directory.
///
/// Why a plain file at the real home — and neither an app group nor
/// `UserDefaults(suiteName:)`: the non-sandboxed host app is denied write access
/// to the app group container (containermanagerd), and the host's cfprefsd
/// domain is separate from the sandboxed extension's, so neither bridges the
/// boundary. The host writes a file it can write (its real Application Support),
/// and the sandboxed extension reads it through a read-only
/// `temporary-exception.files.home-relative-path` entitlement. Both sides resolve
/// the real home via `getpwuid` and read the same relative path from Info.plist,
/// so Release and Debug builds do not accidentally share Finder Sync settings.
enum RightClickConfigurationStore {
    /// Real user home directory, bypassing the sandbox container redirection so
    /// the host app and the sandboxed extension resolve the exact same file.
    private static let realHomeDirectory: String = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return String(cString: home)
        }
        return NSHomeDirectory()
    }()

    /// File path relative to the real home. The extension's read-only
    /// `home-relative-path` entitlement must stay in sync with this build setting.
    static var configFileHomeRelativePath: String {
        if let path = Bundle.main.object(forInfoDictionaryKey: "MTRightClickConfigurationHomeRelativePath") as? String,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return "Library/Application Support/MacTools/right-click-menu.json"
    }

    static var configFileURL: URL {
        URL(fileURLWithPath: realHomeDirectory)
            .appendingPathComponent(configFileHomeRelativePath)
    }

    static func load(from fileURL: URL = configFileURL) -> RightClickConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let configuration = try? JSONDecoder().decode(RightClickConfiguration.self, from: data)
        else {
            return .inactiveDefault
        }
        return configuration
    }

    static func setMenuEnabled(_ enabled: Bool, fileURL: URL = configFileURL) {
        var configuration = load(from: fileURL)
        if enabled, configuration == .inactiveDefault {
            configuration = .activeDefault
        }
        configuration.menuEnabled = enabled
        _ = save(configuration, to: fileURL)
    }

    @discardableResult
    static func save(_ configuration: RightClickConfiguration, to fileURL: URL = configFileURL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
