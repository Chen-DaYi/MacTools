import Foundation
import MacToolsPluginKit

struct ActionInvocationPreset: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let id: UUID
    let reference: ActionReference
    let createdAt: Date

    init(
        id: UUID = UUID(),
        reference: ActionReference,
        createdAt: Date = .now,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.reference = reference
        self.createdAt = createdAt
    }
}

enum ActionInvocationPresetError: Error, Equatable {
    case unknownAction
    case parameterlessAction
    case externalInvocationUnavailable
    case sensitiveParametersUnsupported
    case maximumPresetCountReached
    case persistenceFailed
    case unavailablePreset
}

@MainActor
final class ActionInvocationPresetStore {
    private struct Envelope: Codable {
        let formatVersion: Int
        let presets: [ActionInvocationPreset]
    }

    private enum DefaultsKey {
        static let presets = "actions.run-link-presets.v1"
    }

    static let maximumPresetCount = 256
    static let maximumPayloadByteCount = 512 * 1_024

    private let userDefaults: UserDefaults
    private(set) var loadError: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func presets() -> [ActionInvocationPreset] {
        guard let data = userDefaults.data(forKey: DefaultsKey.presets) else {
            return []
        }
        guard data.count <= Self.maximumPayloadByteCount else {
            loadError = "preset-payload-too-large"
            return []
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.formatVersion == ActionInvocationPreset.currentFormatVersion,
                  envelope.presets.count <= Self.maximumPresetCount,
                  Set(envelope.presets.map(\.id)).count == envelope.presets.count,
                  envelope.presets.allSatisfy({
                      $0.formatVersion == ActionInvocationPreset.currentFormatVersion
                  }) else {
                loadError = "unsupported-preset-format"
                return []
            }
            loadError = nil
            return envelope.presets
        } catch {
            loadError = "invalid-preset-payload"
            return []
        }
    }

    func preset(id: UUID) -> ActionInvocationPreset? {
        presets().first { $0.id == id }
    }

    func preset(reference: ActionReference) -> ActionInvocationPreset? {
        presets().first { $0.reference == reference }
    }

    func create(
        reference: ActionReference,
        registry: ActionRegistry
    ) -> Result<ActionInvocationPreset, ActionInvocationPresetError> {
        let registered: RegisteredAction
        switch registry.registeredAction(for: reference) {
        case let .success(action):
            registered = action
        case .failure:
            return .failure(.unknownAction)
        }
        guard registered.catalogEntry != nil else {
            return .failure(.unknownAction)
        }
        guard !registered.definition.parameters.isEmpty else {
            return .failure(.parameterlessAction)
        }
        guard registered.definition.externalInvocationPolicy != .unavailable else {
            return .failure(.externalInvocationUnavailable)
        }
        let definitionsByID = Dictionary(
            uniqueKeysWithValues: registered.definition.parameters.map { ($0.id, $0) }
        )
        guard reference.parameters.entries.allSatisfy({ entry in
            definitionsByID[entry.name]?.privacy != .sensitive
        }) else {
            return .failure(.sensitiveParametersUnsupported)
        }

        var stored = presets()
        if let existing = stored.first(where: { $0.reference == reference }) {
            return .success(existing)
        }
        guard stored.count < Self.maximumPresetCount else {
            return .failure(.maximumPresetCountReached)
        }
        let preset = ActionInvocationPreset(reference: reference)
        stored.append(preset)
        guard replaceAll(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(preset)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        var stored = presets()
        let originalCount = stored.count
        stored.removeAll { $0.id == id }
        guard stored.count != originalCount else {
            return false
        }
        return replaceAll(stored)
    }

    @discardableResult
    func replaceAll(_ presets: [ActionInvocationPreset]) -> Bool {
        guard presets.count <= Self.maximumPresetCount,
              Set(presets.map(\.id)).count == presets.count,
              presets.allSatisfy({
                  $0.formatVersion == ActionInvocationPreset.currentFormatVersion
              }) else {
            return false
        }
        do {
            let data = try JSONEncoder().encode(
                Envelope(
                    formatVersion: ActionInvocationPreset.currentFormatVersion,
                    presets: presets
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return false
            }
            userDefaults.set(data, forKey: DefaultsKey.presets)
            return userDefaults.data(forKey: DefaultsKey.presets) == data
        } catch {
            return false
        }
    }
}
