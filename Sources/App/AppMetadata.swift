import AppKit
import Foundation

enum AppMetadata {
    static let repositoryDisplayName = "ggbond268/MacTools"

    static var appName: String {
        bundleString("CFBundleDisplayName")
            ?? bundleString(kCFBundleNameKey as String)
            ?? "MacTools"
    }

    static var shortVersion: String? {
        bundleString("CFBundleShortVersionString")
    }

    static var buildNumber: String? {
        bundleString(kCFBundleVersionKey as String)
    }

    static var versionDescription: String {
        formattedVersionDescription(shortVersion: shortVersion, buildNumber: buildNumber)
    }

    static var repositoryURL: URL {
        URL(string: "https://github.com/ggbond268/MacTools")!
    }

    static var aboutDescription: String {
        AppL10n.settings(
            "about.description",
            defaultValue: "一款免费、开源的 macOS 菜单栏工具集合。\n使用 SwiftUI 构建。"
        )
    }

    static var appIcon: NSImage? {
        guard let iconName = bundleString("CFBundleIconName") ?? bundleString("CFBundleIconFile") else {
            return nil
        }

        let imageName = NSImage.Name(iconName)
        return NSImage(named: imageName) ?? Bundle.main.image(forResource: imageName)
    }

    private static func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    static func formattedVersionDescription(shortVersion: String?, buildNumber: String?) -> String {
        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where !shortVersion.isEmpty && !buildNumber.isEmpty:
            return "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _):
            return shortVersion
        case let (_, buildNumber?) where !buildNumber.isEmpty:
            return buildNumber
        default:
            return AppL10n.settings("about.version.unknown", defaultValue: "未知版本")
        }
    }
}
