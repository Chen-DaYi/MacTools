import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionRunLinkServiceTests: XCTestCase {
    func testParameterlessActionHasStableReleaseAndDebugRepresentations() throws {
        let reference = ActionReference(
            key: ActionKey(providerID: "display-sleep", actionID: "sleep")
        )
        let release = try makeService(reference: reference, scheme: "mactools")
        let debug = try makeService(reference: reference, scheme: "mactools-dev")

        XCTAssertEqual(
            release.service.presentation(for: reference),
            .available(
                ActionRunLinkRepresentation(
                    url: "mactools://app/actions/display-sleep/sleep",
                    terminalCommand: "open 'mactools://app/actions/display-sleep/sleep'"
                ),
                presetID: nil
            )
        )
        XCTAssertEqual(
            debug.service.representation(for: .direct(reference.key)).url,
            "mactools-dev://app/actions/display-sleep/sleep"
        )
        XCTAssertEqual(release.service.resolve(.direct(reference.key)), .success(reference))
    }

    func testParameterizedActionRequiresPresetAndResolvesOpaqueID() throws {
        let parameters = try ActionParameterSet(["target": .string("private-device-id")])
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect"),
            parameters: parameters
        )
        let setup = try makeService(
            reference: reference,
            parameterDefinitions: [
                ActionParameterDefinition(id: "target", title: "设备", kind: .string),
            ]
        )

        XCTAssertEqual(setup.service.presentation(for: reference), .needsPreset)
        let representation = try setup.service.createPreset(for: reference).get()
        let preset = try XCTUnwrap(setup.store.preset(reference: reference))

        XCTAssertEqual(
            representation.url,
            "mactools://app/presets/\(preset.id.uuidString.lowercased())"
        )
        XCTAssertFalse(representation.url.contains("private-device-id"))
        XCTAssertEqual(setup.service.resolve(.preset(preset.id)), .success(reference))
        XCTAssertTrue(setup.service.deletePreset(for: reference))
        XCTAssertEqual(
            setup.service.resolve(.preset(preset.id)),
            .failure(.unavailablePreset)
        )
    }

    func testDirectParameterizedAndUnpublishedActionsFailClosed() throws {
        let parameterizedReference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "parameterized"),
            parameters: try ActionParameterSet(["target": .string("one")])
        )
        let parameterized = try makeService(
            reference: parameterizedReference,
            parameterDefinitions: [
                ActionParameterDefinition(id: "target", title: "目标", kind: .string),
            ]
        )
        XCTAssertEqual(
            parameterized.service.resolve(.direct(parameterizedReference.key)),
            .failure(.parameterizedDirectAction)
        )

        let unpublishedReference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "unpublished")
        )
        let unpublished = try makeService(reference: unpublishedReference, publish: false)
        XCTAssertEqual(
            unpublished.service.presentation(for: unpublishedReference),
            .unavailable("此操作尚未发布到操作目录。")
        )
        XCTAssertEqual(
            unpublished.service.resolve(.direct(unpublishedReference.key)),
            .failure(.unknownAction)
        )
    }

    func testPresetRetainsMissingProviderAndRecoversWhenProviderReturns() throws {
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "parameterized"),
            parameters: try ActionParameterSet(["target": .string("one")])
        )
        let setup = try makeService(
            reference: reference,
            parameterDefinitions: [
                ActionParameterDefinition(id: "target", title: "目标", kind: .string),
            ]
        )
        _ = try setup.service.createPreset(for: reference).get()
        let presetID = try XCTUnwrap(setup.store.preset(reference: reference)?.id)

        setup.registry.synchronize([])
        XCTAssertEqual(setup.service.resolve(.preset(presetID)), .failure(.unknownAction))
        XCTAssertNotNil(setup.store.preset(id: presetID))

        setup.registry.synchronize([setup.registration])
        XCTAssertEqual(setup.service.resolve(.preset(presetID)), .success(reference))
    }

    func testForgedSensitivePresetIsRejectedDuringResolution() throws {
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "sensitive"),
            parameters: try ActionParameterSet(["secret": .string("never-display")])
        )
        let setup = try makeService(
            reference: reference,
            parameterDefinitions: [
                ActionParameterDefinition(
                    id: "secret",
                    title: "密钥",
                    kind: .string,
                    privacy: .sensitive
                ),
            ]
        )
        let forged = ActionInvocationPreset(reference: reference)
        XCTAssertTrue(setup.store.replaceAll([forged]))

        XCTAssertEqual(
            setup.service.resolve(.preset(forged.id)),
            .failure(.sensitiveParametersUnsupported)
        )
    }

    func testPresetReferenceMigratesAndPersistsBeforeResolution() throws {
        let key = ActionKey(providerID: "test-provider", actionID: "migrated")
        let current = ActionReference(key: key, schemaVersion: 2)
        let setup = try makeService(
            reference: current,
            schemaVersion: 2,
            migrate: { reference, version in
                ActionReference(
                    key: reference.key,
                    schemaVersion: version,
                    parameters: reference.parameters
                )
            }
        )
        let preset = ActionInvocationPreset(
            reference: ActionReference(key: key, schemaVersion: 1)
        )
        XCTAssertTrue(setup.store.replaceAll([preset]))

        XCTAssertEqual(setup.service.resolve(.preset(preset.id)), .success(current))
        XCTAssertEqual(setup.store.preset(id: preset.id)?.reference, current)
    }

    private struct Setup {
        let registry: ActionRegistry
        let registration: ActionProviderRegistration
        let store: ActionInvocationPresetStore
        let service: ActionRunLinkService
        let defaults: UserDefaults
    }

    private func makeService(
        reference: ActionReference,
        scheme: String = "mactools",
        schemaVersion: Int = 1,
        parameterDefinitions: [ActionParameterDefinition] = [],
        externalPolicy: ActionExternalInvocationPolicy = .allowed,
        publish: Bool = true,
        migrate: @escaping (ActionReference, Int) -> ActionReference? = { reference, version in
            reference.schemaVersion == version ? reference : nil
        }
    ) throws -> Setup {
        let registry = ActionRegistry()
        let definition = ActionDefinition(
            key: reference.key,
            parameterSchemaVersion: schemaVersion,
            title: "测试操作",
            description: "测试运行链接",
            systemImage: "link",
            parameters: parameterDefinitions,
            externalInvocationPolicy: externalPolicy,
            capabilities: [.background, .foregroundInteractive]
        )
        let registration = ActionProviderRegistration(
            providerID: reference.key.providerID,
            identity: ObjectIdentifier(registry),
            definitions: [definition],
            catalogEntries: publish
                ? [ActionCatalogEntry(reference: reference, title: definition.title)]
                : [],
            availability: { _ in .available },
            migrate: migrate,
            begin: { _ in
                .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
        registry.synchronize([registration])
        let suite = "ActionRunLinkServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ActionInvocationPresetStore(userDefaults: defaults)
        return Setup(
            registry: registry,
            registration: registration,
            store: store,
            service: ActionRunLinkService(
                registry: registry,
                presetStore: store,
                scheme: scheme
            ),
            defaults: defaults
        )
    }
}
