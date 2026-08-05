import Foundation

public struct ActionKey: Hashable, Codable, Sendable, Identifiable {
    public let providerID: String
    public let actionID: String

    public init(providerID: String, actionID: String) {
        self.providerID = providerID
        self.actionID = actionID
    }

    public var id: String {
        "\(providerID)/\(actionID)"
    }
}

public enum ActionParameterValue: Hashable, Codable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case double
        case boolean
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double:
            let value = try container.decode(Double.self, forKey: .value)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Action parameter doubles must be finite."
                )
            }
            self = .double(value)
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .double(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Action parameter doubles must be finite."
                    )
                )
            }
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum ActionParameterSetError: Error, Equatable, Sendable {
    case tooManyEntries
    case invalidName(String)
    case duplicateName(String)
    case stringTooLong(String)
    case nonFiniteNumber(String)
    case payloadTooLarge
}

public struct ActionParameterSet: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public let name: String
        public let value: ActionParameterValue

        public init(name: String, value: ActionParameterValue) {
            self.name = name
            self.value = value
        }
    }

    public static let maximumEntryCount = 32
    public static let maximumNameByteCount = 128
    public static let maximumStringByteCount = 4 * 1_024
    public static let maximumPayloadByteCount = 16 * 1_024

    public static let empty = try! ActionParameterSet(entries: [])

    public let entries: [Entry]

    public init(entries: [Entry]) throws {
        guard entries.count <= Self.maximumEntryCount else {
            throw ActionParameterSetError.tooManyEntries
        }

        let sortedEntries = entries.sorted { $0.name < $1.name }
        var previousName: String?
        var payloadByteCount = 0

        for entry in sortedEntries {
            guard Self.isValidName(entry.name) else {
                throw ActionParameterSetError.invalidName(entry.name)
            }
            guard entry.name != previousName else {
                throw ActionParameterSetError.duplicateName(entry.name)
            }
            previousName = entry.name
            payloadByteCount += entry.name.utf8.count

            switch entry.value {
            case let .string(value):
                guard value.utf8.count <= Self.maximumStringByteCount else {
                    throw ActionParameterSetError.stringTooLong(entry.name)
                }
                payloadByteCount += value.utf8.count
            case let .double(value):
                guard value.isFinite else {
                    throw ActionParameterSetError.nonFiniteNumber(entry.name)
                }
                payloadByteCount += 16
            case .integer, .boolean:
                payloadByteCount += 16
            }
        }

        guard payloadByteCount <= Self.maximumPayloadByteCount else {
            throw ActionParameterSetError.payloadTooLarge
        }
        self.entries = sortedEntries
    }

    public init(_ values: [String: ActionParameterValue]) throws {
        try self.init(entries: values.map(Entry.init))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(entries: container.decode([Entry].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    public subscript(name: String) -> ActionParameterValue? {
        entries.first(where: { $0.name == name })?.value
    }

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameByteCount else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
        }
    }
}

public enum ActionParameterKind: String, Hashable, Codable, Sendable {
    case string
    case integer
    case double
    case boolean

    public func accepts(_ value: ActionParameterValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.integer, .integer), (.double, .double), (.boolean, .boolean):
            return true
        default:
            return false
        }
    }
}

public enum ActionParameterPrivacy: String, Hashable, Codable, Sendable {
    case publicValue
    case sensitive
}

public enum ActionParameterPortability: String, Hashable, Codable, Sendable {
    case portable
    case localOnly
}

public struct ActionParameterDefinition: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ActionParameterKind
    public let isRequired: Bool
    public let privacy: ActionParameterPrivacy
    public let portability: ActionParameterPortability

    public init(
        id: String,
        title: String,
        kind: ActionParameterKind,
        isRequired: Bool = true,
        privacy: ActionParameterPrivacy = .publicValue,
        portability: ActionParameterPortability = .portable
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isRequired = isRequired
        self.privacy = privacy
        self.portability = portability
    }
}

public enum ActionRisk: String, Hashable, Codable, Sendable {
    case safe
    case confirmationRequired
}

public enum ActionExternalInvocationPolicy: String, Hashable, Codable, Sendable {
    case unavailable
    case allowed
    case confirmAlways
}

public struct ActionExecutionCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public static let background = ActionExecutionCapabilities(rawValue: 1 << 0)
    public static let foregroundInteractive = ActionExecutionCapabilities(rawValue: 1 << 1)
    public static let cancellable = ActionExecutionCapabilities(rawValue: 1 << 2)
    public static let reportsProgress = ActionExecutionCapabilities(rawValue: 1 << 3)

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

public struct ActionConfirmation: Hashable, Codable, Sendable {
    public let title: String
    public let message: String
    public let confirmButtonTitle: String

    public init(title: String, message: String, confirmButtonTitle: String) {
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
    }
}

public struct ActionDefinition: Hashable, Codable, Sendable, Identifiable {
    public let key: ActionKey
    public let parameterSchemaVersion: Int
    public let title: String
    public let description: String
    public let keywords: [String]
    public let systemImage: String
    public let parameters: [ActionParameterDefinition]
    public let risk: ActionRisk
    public let confirmation: ActionConfirmation?
    public let externalInvocationPolicy: ActionExternalInvocationPolicy
    public let capabilities: ActionExecutionCapabilities
    public let executionTimeoutSeconds: Double?

    public init(
        key: ActionKey,
        parameterSchemaVersion: Int = 1,
        title: String,
        description: String,
        keywords: [String] = [],
        systemImage: String,
        parameters: [ActionParameterDefinition] = [],
        risk: ActionRisk = .safe,
        confirmation: ActionConfirmation? = nil,
        externalInvocationPolicy: ActionExternalInvocationPolicy = .unavailable,
        capabilities: ActionExecutionCapabilities = [.foregroundInteractive],
        executionTimeoutSeconds: Double? = 30
    ) {
        self.key = key
        self.parameterSchemaVersion = parameterSchemaVersion
        self.title = title
        self.description = description
        self.keywords = keywords
        self.systemImage = systemImage
        self.parameters = parameters
        self.risk = risk
        self.confirmation = confirmation
        self.externalInvocationPolicy = externalInvocationPolicy
        self.capabilities = capabilities
        self.executionTimeoutSeconds = executionTimeoutSeconds
    }

    public var id: ActionKey {
        key
    }
}

public struct ActionReference: Hashable, Codable, Sendable, Identifiable {
    public let key: ActionKey
    public let schemaVersion: Int
    public let parameters: ActionParameterSet

    private enum CodingKeys: String, CodingKey {
        case key
        case schemaVersion
        case parameters
    }

    public init(
        key: ActionKey,
        schemaVersion: Int = 1,
        parameters: ActionParameterSet = .empty
    ) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.parameters = parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(ActionKey.self, forKey: .key)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        parameters = try container.decode(ActionParameterSet.self, forKey: .parameters)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(parameters, forKey: .parameters)
    }

    public var id: ActionReference {
        self
    }
}

public struct ActionCatalogEntry: Hashable, Codable, Sendable, Identifiable {
    public let reference: ActionReference
    public let title: String
    public let subtitle: String?

    public init(reference: ActionReference, title: String, subtitle: String? = nil) {
        self.reference = reference
        self.title = title
        self.subtitle = subtitle
    }

    public var id: ActionReference {
        reference
    }
}

public struct ActionAvailability: Hashable, Codable, Sendable {
    public let isAvailable: Bool
    public let reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }

    public static let available = ActionAvailability(isAvailable: true)

    public static func unavailable(_ reason: String) -> ActionAvailability {
        ActionAvailability(isAvailable: false, reason: reason)
    }
}

public enum ActionExecutionSource: String, Hashable, Codable, Sendable {
    case unifiedSearch
    case globalShortcut
    case runLink
    case workflow
    case actionGrid
    case manual
    case test
}

public enum ActionExecutionMode: String, Hashable, Codable, Sendable {
    case background
    case foreground
}

public struct ActionInvocation: Hashable, Codable, Sendable {
    public let reference: ActionReference
    public let source: ActionExecutionSource
    public let mode: ActionExecutionMode

    public init(
        reference: ActionReference,
        source: ActionExecutionSource,
        mode: ActionExecutionMode
    ) {
        self.reference = reference
        self.source = source
        self.mode = mode
    }
}

public enum ActionExecutionResult: Equatable, Sendable {
    case succeeded(message: String? = nil)
    case failed(message: String)
    case cancelled
}

@MainActor
public final class ActionExecutionHandle {
    private let operation: @MainActor () async -> ActionExecutionResult
    private let cancellationHandler: @MainActor () -> Void
    private var task: Task<ActionExecutionResult, Never>?

    public init(
        operation: @escaping @MainActor () async -> ActionExecutionResult,
        cancel: @escaping @MainActor () -> Void = {}
    ) {
        self.operation = operation
        self.cancellationHandler = cancel
    }

    public func result() async -> ActionExecutionResult {
        if let task {
            return await task.value
        }

        let operation = self.operation
        let task = Task { @MainActor in
            await operation()
        }
        self.task = task
        return await task.value
    }

    public func cancel() {
        task?.cancel()
        cancellationHandler()
    }
}

@MainActor
public protocol PluginActionProviding: AnyObject {
    var actionDefinitions: [ActionDefinition] { get }
    var actionCatalogEntries: [ActionCatalogEntry] { get }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability
    func migrateActionReference(
        _ reference: ActionReference,
        toSchemaVersion schemaVersion: Int
    ) -> ActionReference?
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle
}

public struct LegacyActionShortcutAssignment: Hashable, Codable, Sendable {
    public let reference: ActionReference
    public let binding: ShortcutBinding
    public let legacyShortcutDefinitionID: String?

    public init(
        reference: ActionReference,
        binding: ShortcutBinding,
        legacyShortcutDefinitionID: String? = nil
    ) {
        self.reference = reference
        self.binding = binding
        self.legacyShortcutDefinitionID = legacyShortcutDefinitionID
    }
}

/// Optional one-shot bridge for plugins that registered ordinary shortcuts before actions existed.
/// The host persists the returned assignments before invoking the completion callback.
@MainActor
public protocol PluginLegacyActionShortcutProviding: AnyObject {
    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] { get }
    func legacyActionShortcutsDidMigrate()
}

public extension PluginActionProviding {
    var actionCatalogEntries: [ActionCatalogEntry] {
        actionDefinitions.compactMap { definition in
            guard definition.parameters.isEmpty else {
                return nil
            }
            return ActionCatalogEntry(
                reference: ActionReference(
                    key: definition.key,
                    schemaVersion: definition.parameterSchemaVersion
                ),
                title: definition.title
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        .available
    }

    func migrateActionReference(
        _ reference: ActionReference,
        toSchemaVersion schemaVersion: Int
    ) -> ActionReference? {
        guard reference.schemaVersion == schemaVersion else {
            return nil
        }
        return reference
    }
}
