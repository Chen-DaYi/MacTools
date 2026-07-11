import Foundation

public struct PluginLocalization: @unchecked Sendable {
    public let bundle: Bundle
    public let table: String?

    public init(bundle: Bundle, table: String? = nil) {
        self.bundle = bundle
        self.table = table
    }

    public func string(_ key: String, defaultValue: String) -> String {
        PluginRuntimeLocalization.string(
            key,
            defaultValue: defaultValue,
            table: table,
            bundle: bundle
        )
    }

    public func format(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }
}
