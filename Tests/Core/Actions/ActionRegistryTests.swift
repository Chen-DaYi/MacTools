import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionRegistryTests: XCTestCase {
    func testRegistryRejectsUnknownParametersAndInvalidProviderDefinitions() throws {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition(
            parameters: [
                ActionParameterDefinition(id: "enabled", title: "启用", kind: .boolean),
            ]
        )
        let issues = registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: []),
        ])
        XCTAssertTrue(issues.isEmpty)

        let invalidReference = ActionReference(
            key: definition.key,
            parameters: try ActionParameterSet(["other": .boolean(true)])
        )
        XCTAssertEqual(
            registry.registeredAction(for: invalidReference),
            .failure(.invalidParameters("unknown-parameter:other"))
        )

        let invalidDefinition = ActionDefinition(
            key: ActionKey(providerID: "different-provider", actionID: "toggle"),
            title: "切换",
            description: "",
            systemImage: "switch.2"
        )
        XCTAssertEqual(
            registry.synchronize([
                provider.registration(definitions: [invalidDefinition], catalogEntries: []),
            ]),
            [.invalidDefinition(invalidDefinition.key, "provider-mismatch")]
        )
    }

    func testRegistryRetainsGenerationForIdenticalProviderAndInvalidatesChangedProvider() {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition()
        let entry = ActionCatalogEntry(
            reference: ActionReference(key: definition.key),
            title: definition.title
        )

        registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: [entry]),
        ])
        let first = try! registry.registeredAction(for: entry.reference).get()

        registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: [entry]),
        ])
        let unchanged = try! registry.registeredAction(for: entry.reference).get()
        XCTAssertEqual(unchanged.providerGeneration, first.providerGeneration)

        let renamed = ActionDefinition(
            key: definition.key,
            title: "新的标题",
            description: definition.description,
            systemImage: definition.systemImage
        )
        registry.synchronize([
            provider.registration(definitions: [renamed], catalogEntries: []),
        ])
        let changed = try! registry.registeredAction(
            for: ActionReference(key: definition.key)
        ).get()
        XCTAssertNotEqual(changed.providerGeneration, first.providerGeneration)
    }

    func testOneDefinitionCanPublishMultipleConcreteCatalogEntries() throws {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition(
            parameters: [
                ActionParameterDefinition(id: "display", title: "显示器", kind: .string),
            ]
        )
        let internalDisplay = ActionCatalogEntry(
            reference: ActionReference(
                key: definition.key,
                parameters: try ActionParameterSet(["display": .string("internal")])
            ),
            title: "内建显示器"
        )
        let externalDisplay = ActionCatalogEntry(
            reference: ActionReference(
                key: definition.key,
                parameters: try ActionParameterSet(["display": .string("external")])
            ),
            title: "外接显示器"
        )

        registry.synchronize([
            provider.registration(
                definitions: [definition],
                catalogEntries: [internalDisplay, externalDisplay]
            ),
        ])

        XCTAssertEqual(Set(registry.catalogEntries), Set([internalDisplay, externalDisplay]))
    }
}

@MainActor
final class ActionRegistryTestProvider {
    var availability: ActionAvailability = .available
    var beginResult: ActionExecutionResult = .succeeded()

    func registration(
        definitions: [ActionDefinition],
        catalogEntries: [ActionCatalogEntry]
    ) -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: "test-provider",
            identity: ObjectIdentifier(self),
            definitions: definitions,
            catalogEntries: catalogEntries,
            availability: { [weak self] _ in
                self?.availability ?? .unavailable("missing")
            },
            begin: { [weak self] _ in
                guard let self else {
                    return .failure(.providerFailure("missing"))
                }
                let result = self.beginResult
                return .success(
                    ActionExecutionHandle(operation: { result })
                )
            }
        )
    }
}

func makeActionDefinition(
    parameters: [ActionParameterDefinition] = [],
    risk: ActionRisk = .safe,
    confirmation: ActionConfirmation? = nil,
    externalPolicy: ActionExternalInvocationPolicy = .allowed,
    capabilities: ActionExecutionCapabilities = [.background, .foregroundInteractive],
    timeout: Double? = 30
) -> ActionDefinition {
    ActionDefinition(
        key: ActionKey(providerID: "test-provider", actionID: "toggle"),
        title: "切换",
        description: "切换测试状态",
        systemImage: "switch.2",
        parameters: parameters,
        risk: risk,
        confirmation: confirmation,
        externalInvocationPolicy: externalPolicy,
        capabilities: capabilities,
        executionTimeoutSeconds: timeout
    )
}
