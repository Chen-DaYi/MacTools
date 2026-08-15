import Foundation
import MacToolsPluginKit

enum ActionRunLinkRequest: Hashable, Sendable {
    case direct(ActionKey)
    case preset(UUID)
}

struct ActionRunLinkRepresentation: Equatable, Sendable {
    let url: String
    let terminalCommand: String
}

enum ActionRunLinkPresentation: Equatable, Sendable {
    case available(ActionRunLinkRepresentation, presetID: UUID?)
    case needsPreset
    case unavailable(String)
}

enum ActionRunLinkResolutionError: Error, Equatable {
    case unknownAction
    case unavailablePreset
    case parameterizedDirectAction
    case externalInvocationUnavailable
    case sensitiveParametersUnsupported
}

@MainActor
final class ActionRunLinkService {
    private let registry: ActionRegistry
    private let presetStore: ActionInvocationPresetStore
    private let scheme: String

    init(
        registry: ActionRegistry,
        presetStore: ActionInvocationPresetStore,
        scheme: String
    ) {
        precondition(Self.isValidScheme(scheme))
        self.registry = registry
        self.presetStore = presetStore
        self.scheme = scheme.lowercased()
    }

    func presentation(for reference: ActionReference) -> ActionRunLinkPresentation {
        guard canonicalizeStoredPresets() else {
            return .unavailable(FeatureL10n.string("无法保存运行链接预设。"))
        }
        let reference = canonicalReference(for: reference)
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return .unavailable(FeatureL10n.string("操作提供方当前不可用。"))
        }
        guard action.catalogEntry != nil else {
            return .unavailable(FeatureL10n.string("此操作尚未发布到操作目录。"))
        }
        guard action.definition.externalInvocationPolicy != .unavailable else {
            return .unavailable(FeatureL10n.string("此操作不能通过运行链接调用。"))
        }

        if action.definition.parameters.isEmpty {
            return .available(
                representation(for: .direct(reference.key)),
                presetID: nil
            )
        }
        guard !containsSensitiveParameters(
            reference,
            definitions: action.definition.parameters
        ) else {
            return .unavailable(FeatureL10n.string("包含敏感参数的操作不能创建运行链接。"))
        }
        guard let preset = presetStore.preset(reference: reference) else {
            return .needsPreset
        }
        return .available(
            representation(for: .preset(preset.id)),
            presetID: preset.id
        )
    }

    func createPreset(
        for reference: ActionReference
    ) -> Result<ActionRunLinkRepresentation, ActionInvocationPresetError> {
        guard canonicalizeStoredPresets() else {
            return .failure(.persistenceFailed)
        }
        let reference = canonicalReference(for: reference)
        return presetStore.create(reference: reference, registry: registry).map { preset in
            representation(for: .preset(preset.id))
        }
    }

    @discardableResult
    func deletePreset(for reference: ActionReference) -> Bool {
        guard canonicalizeStoredPresets() else { return false }
        return presetStore.delete(reference: canonicalReference(for: reference))
    }

    private func canonicalReference(for reference: ActionReference) -> ActionReference {
        guard case let .success(migrated) = registry.migrate(reference) else {
            return reference
        }
        return migrated
    }

    private func canonicalizeStoredPresets() -> Bool {
        let stored = presetStore.presets()
        guard presetStore.loadError == nil else { return false }
        let canonical = stored.map { preset in
            let reference = canonicalReference(for: preset.reference)
            guard reference != preset.reference else { return preset }
            return ActionInvocationPreset(
                id: preset.id,
                reference: reference,
                createdAt: preset.createdAt,
                formatVersion: preset.formatVersion
            )
        }
        return canonical == stored || presetStore.replaceAll(canonical)
    }

    func resolve(
        _ request: ActionRunLinkRequest
    ) -> Result<ActionReference, ActionRunLinkResolutionError> {
        let reference: ActionReference
        switch request {
        case let .direct(key):
            guard let definition = registry.definition(for: key) else {
                return .failure(.unknownAction)
            }
            guard definition.parameters.isEmpty else {
                return .failure(.parameterizedDirectAction)
            }
            reference = ActionReference(
                key: key,
                schemaVersion: definition.parameterSchemaVersion
            )
            guard case let .success(action) = registry.registeredAction(for: reference) else {
                return .failure(.unknownAction)
            }
            guard action.catalogEntry != nil else {
                return .failure(.unknownAction)
            }
        case let .preset(id):
            guard let preset = presetStore.preset(id: id) else {
                return .failure(.unavailablePreset)
            }
            switch registry.migrate(preset.reference) {
            case let .success(migrated):
                reference = migrated
                guard presetStore.updateReference(id: id, reference: migrated) else {
                    return .failure(.unavailablePreset)
                }
            case .failure:
                return .failure(.unknownAction)
            }
            guard case let .success(action) = registry.registeredAction(for: reference),
                  action.catalogEntry != nil else {
                return .failure(.unknownAction)
            }
            guard !containsSensitiveParameters(
                reference,
                definitions: action.definition.parameters
            ) else {
                return .failure(.sensitiveParametersUnsupported)
            }
        }

        guard case let .success(action) = registry.registeredAction(for: reference),
              action.definition.externalInvocationPolicy != .unavailable else {
            return .failure(.externalInvocationUnavailable)
        }
        return .success(reference)
    }

    private func containsSensitiveParameters(
        _ reference: ActionReference,
        definitions: [ActionParameterDefinition]
    ) -> Bool {
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        return reference.parameters.entries.contains { entry in
            definitionsByID[entry.name]?.privacy == .sensitive
        }
    }

    func representation(for request: ActionRunLinkRequest) -> ActionRunLinkRepresentation {
        let path: String
        switch request {
        case let .direct(key):
            path = "actions/\(key.providerID)/\(key.actionID)"
        case let .preset(id):
            path = "presets/\(id.uuidString.lowercased())"
        }
        let url = "\(scheme)://app/\(path)"
        return ActionRunLinkRepresentation(
            url: url,
            terminalCommand: "open '\(url)'"
        )
    }

    private static func isValidScheme(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.contains(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "+"
                || scalar == "-"
                || scalar == "."
        }
    }
}
