import Foundation

public struct PluginLocalization: @unchecked Sendable {
    public let bundle: Bundle
    public let table: String?

    public init(bundle: Bundle, table: String? = nil) {
        self.bundle = bundle
        self.table = table
    }

    public func string(_ key: String, defaultValue: String) -> String {
        bundle.localizedString(forKey: key, value: defaultValue, table: table)
    }

    public func format(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key, defaultValue: defaultValue),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
