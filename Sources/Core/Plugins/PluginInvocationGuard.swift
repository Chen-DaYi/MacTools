import Foundation

enum PluginInvocationFailure: LocalizedError {
    case swiftError(Error)
    case objectiveCException(name: String, reason: String?)
    case missingReturnValue

    var errorDescription: String? {
        switch self {
        case let .swiftError(error):
            return error.localizedDescription
        case let .objectiveCException(name, reason):
            if let reason, !reason.isEmpty {
                return "\(name)：\(reason)"
            }

            return name
        case .missingReturnValue:
            return AppL10n.plugins("plugin.error.invocation.missingReturnValue", defaultValue: "插件调用未返回结果。")
        }
    }
}

enum PluginInvocationGuard {
    static func run(
        operation: String,
        _ body: () throws -> Void
    ) -> Result<Void, PluginInvocationFailure> {
        var swiftError: Error?
        let exception = MTPluginInvocationCatcher.catchException(in: {
            do {
                try body()
            } catch {
                swiftError = error
            }
        })

        if let exception {
            return .failure(
                .objectiveCException(
                    name: exception.name.rawValue,
                    reason: exception.reason
                )
            )
        }

        if let swiftError {
            return .failure(.swiftError(swiftError))
        }

        return .success(())
    }

    static func value<T>(
        operation: String,
        _ body: () throws -> T
    ) -> Result<T, PluginInvocationFailure> {
        var value: T?
        let result = run(operation: operation) {
            value = try body()
        }

        switch result {
        case .success:
            guard let value else {
                return .failure(.missingReturnValue)
            }

            return .success(value)
        case let .failure(failure):
            return .failure(failure)
        }
    }
}
