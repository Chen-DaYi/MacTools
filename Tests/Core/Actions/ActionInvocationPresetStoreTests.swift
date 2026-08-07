import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionInvocationPresetStoreTests: XCTestCase {
    func testCreateReusesVersionedPresetAndDeleteInvalidatesIt() throws {
        let (defaults, suite) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = parameterizedDefinition()
        let reference = try publicReference(for: definition)
        registry.synchronize([
            provider.registration(
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "目标操作")]
            ),
        ])
        let store = ActionInvocationPresetStore(userDefaults: defaults)

        let first = try store.create(reference: reference, registry: registry).get()
        let second = try store.create(reference: reference, registry: registry).get()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.formatVersion, ActionInvocationPreset.currentFormatVersion)
        XCTAssertEqual(store.preset(id: first.id), first)
        XCTAssertTrue(store.delete(id: first.id))
        XCTAssertNil(store.preset(id: first.id))
        XCTAssertFalse(store.delete(id: first.id))
    }

    func testCreateRejectsParameterlessUnpublishedIneligibleAndSensitiveActions() throws {
        let (defaults, suite) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let parameterless = makeActionDefinition()
        let unpublished = parameterizedDefinition(actionID: "unpublished")
        let ineligible = parameterizedDefinition(
            actionID: "ineligible",
            externalPolicy: .unavailable
        )
        let sensitive = parameterizedDefinition(
            actionID: "sensitive",
            privacy: .sensitive
        )
        let ineligibleReference = try publicReference(for: ineligible)
        let sensitiveReference = try publicReference(for: sensitive)
        registry.synchronize([
            provider.registration(
                definitions: [parameterless, unpublished, ineligible, sensitive],
                catalogEntries: [
                    ActionCatalogEntry(
                        reference: ActionReference(key: parameterless.key),
                        title: "无参数操作"
                    ),
                    ActionCatalogEntry(reference: ineligibleReference, title: "不可外部调用"),
                    ActionCatalogEntry(reference: sensitiveReference, title: "敏感操作"),
                ]
            ),
        ])
        let store = ActionInvocationPresetStore(userDefaults: defaults)

        XCTAssertEqual(
            store.create(
                reference: ActionReference(key: parameterless.key),
                registry: registry
            ),
            .failure(.parameterlessAction)
        )
        XCTAssertEqual(
            store.create(reference: try publicReference(for: unpublished), registry: registry),
            .failure(.unknownAction)
        )
        XCTAssertEqual(
            store.create(reference: ineligibleReference, registry: registry),
            .failure(.externalInvocationUnavailable)
        )
        XCTAssertEqual(
            store.create(reference: sensitiveReference, registry: registry),
            .failure(.sensitiveParametersUnsupported)
        )
    }

    func testStoredPresetSurvivesTemporarilyMissingProvider() throws {
        let (defaults, suite) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = parameterizedDefinition()
        let reference = try publicReference(for: definition)
        registry.synchronize([
            provider.registration(
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "目标操作")]
            ),
        ])
        let store = ActionInvocationPresetStore(userDefaults: defaults)
        let preset = try store.create(reference: reference, registry: registry).get()

        registry.synchronize([])

        XCTAssertEqual(store.preset(id: preset.id), preset)
        XCTAssertEqual(store.preset(reference: reference), preset)
    }

    func testCorruptFutureAndOversizedPayloadsFailClosedWithoutDeletingData() throws {
        let (defaults, suite) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "actions.run-link-presets.v1"
        let store = ActionInvocationPresetStore(userDefaults: defaults)

        defaults.set(Data("not-json".utf8), forKey: key)
        XCTAssertTrue(store.presets().isEmpty)
        XCTAssertEqual(store.loadError, "invalid-preset-payload")
        XCTAssertNotNil(defaults.data(forKey: key))

        defaults.set(Data(#"{"formatVersion":2,"presets":[]}"#.utf8), forKey: key)
        XCTAssertTrue(store.presets().isEmpty)
        XCTAssertEqual(store.loadError, "unsupported-preset-format")

        let oversized = Data(
            repeating: 0,
            count: ActionInvocationPresetStore.maximumPayloadByteCount + 1
        )
        defaults.set(oversized, forKey: key)
        XCTAssertTrue(store.presets().isEmpty)
        XCTAssertEqual(store.loadError, "preset-payload-too-large")
        XCTAssertEqual(defaults.data(forKey: key), oversized)
    }

    func testStoreEnforcesPresetCountAndPayloadBounds() throws {
        let (defaults, suite) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActionInvocationPresetStore(userDefaults: defaults)
        let presets = (0..<ActionInvocationPresetStore.maximumPresetCount).map { index in
            ActionInvocationPreset(
                id: deterministicUUID(index),
                reference: ActionReference(
                    key: ActionKey(providerID: "test-provider", actionID: "toggle-\(index)")
                ),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertTrue(store.replaceAll(presets))
        XCTAssertEqual(store.presets().count, ActionInvocationPresetStore.maximumPresetCount)
        XCTAssertFalse(
            store.replaceAll(
                presets + [ActionInvocationPreset(
                    reference: ActionReference(
                        key: ActionKey(providerID: "test-provider", actionID: "overflow")
                    )
                )]
            )
        )
    }

    func testStoreRejectsDuplicateReferencesEvenWithUniqueIDs() throws {
        let (defaults, suite) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActionInvocationPresetStore(userDefaults: defaults)
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "toggle")
        )

        XCTAssertFalse(store.replaceAll([
            ActionInvocationPreset(id: deterministicUUID(1), reference: reference),
            ActionInvocationPreset(id: deterministicUUID(2), reference: reference),
        ]))
        XCTAssertTrue(store.presets().isEmpty)
    }

    private func parameterizedDefinition(
        actionID: String = "parameterized",
        externalPolicy: ActionExternalInvocationPolicy = .allowed,
        privacy: ActionParameterPrivacy = .publicValue
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: "test-provider", actionID: actionID),
            title: "参数操作",
            description: "测试参数操作",
            systemImage: "slider.horizontal.3",
            parameters: [
                ActionParameterDefinition(
                    id: "target",
                    title: "目标",
                    kind: .string,
                    privacy: privacy
                ),
            ],
            externalInvocationPolicy: externalPolicy,
            capabilities: [.background, .foregroundInteractive]
        )
    }

    private func publicReference(for definition: ActionDefinition) throws -> ActionReference {
        ActionReference(
            key: definition.key,
            parameters: try ActionParameterSet(["target": .string("display-1")])
        )
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suite = "ActionInvocationPresetStoreTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
