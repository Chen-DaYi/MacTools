import Carbon
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ShortcutAssignmentServiceTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutAssignmentServiceTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAssignmentPersistsAndRegistersThroughInjectedCarbonRegistrar() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: reference),
            .success
        )

        let item = try XCTUnwrap(harness.service.settingsItems.first)
        XCTAssertEqual(item.assignment.reference, reference)
        XCTAssertEqual(item.state, .registered)
        XCTAssertEqual(harness.registrar.registeredBindings, [harness.bindings[0]])
        XCTAssertEqual(
            harness.service.reference(
                forShortcutID: try XCTUnwrap(
                    harness.manager.debugRegistrationsForTests.first {
                        $0.binding == harness.bindings[0]
                    }?.shortcutID
                )
            ),
            reference
        )

        let reloadedStore = ActionShortcutAssignmentStore(userDefaults: harness.defaults)
        XCTAssertEqual(reloadedStore.assignments(), harness.service.assignments)
    }

    func testConflictReplacementIsAtomicAndReservedBindingsCannotBeReplaced() throws {
        let harness = try makeHarness()
        let first = harness.references[0]
        let second = harness.references[1]
        XCTAssertEqual(harness.service.assign(harness.bindings[0], to: first), .success)

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: second),
            .failure(.conflict(ownerDescription: "操作 1"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [first])

        XCTAssertEqual(
            harness.service.assign(
                harness.bindings[0],
                to: second,
                replacingConflictingActionAssignments: true
            ),
            .success
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [second])

        let reserved = GlobalShortcutManager.Registration(
            shortcutID: "special.release-aware",
            binding: harness.bindings[1]
        )
        harness.service.synchronize(
            reservedRegistrations: [reserved],
            reservedOwnerDescriptions: [reserved.shortcutID: "亮度连续调节"]
        )
        XCTAssertEqual(
            harness.service.assign(
                harness.bindings[1],
                to: first,
                replacingConflictingActionAssignments: true
            ),
            .failure(.conflict(ownerDescription: "亮度连续调节"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [second])
    }

    func testUnavailableAssignmentsAreRetainedButNotRegistered() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]
        XCTAssertEqual(harness.service.assign(harness.bindings[0], to: reference), .success)

        harness.registry.synchronize([])
        harness.service.synchronize(
            reservedRegistrations: [],
            reservedOwnerDescriptions: [:]
        )

        XCTAssertEqual(harness.service.assignments.first?.reference, reference)
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .unavailable(reason: FeatureL10n.string("操作不可用。"))
        )
        XCTAssertFalse(
            harness.manager.debugRegistrationsForTests.contains {
                $0.binding == harness.bindings[0]
            }
        )
    }

    func testCarbonRegistrationFailureIsVisibleAndRecoverable() throws {
        let harness = try makeHarness()
        harness.registrar.failures[harness.bindings[0]] = -9876

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .registrationFailed(code: -9876)
        )

        harness.registrar.failures.removeAll()
        harness.service.synchronize(
            reservedRegistrations: [],
            reservedOwnerDescriptions: [:]
        )
        XCTAssertEqual(harness.service.settingsItems.first?.state, .registered)
    }

    func testBindingRevisionChangesOnlyWhenPublishedAssignmentStateChanges() throws {
        let harness = try makeHarness()
        let initialRevision = harness.service.revision

        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(harness.service.revision, initialRevision)

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        let assignedRevision = harness.service.revision
        XCTAssertEqual(assignedRevision, initialRevision + 1)

        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(harness.service.revision, assignedRevision)

        harness.registry.synchronize([])
        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(harness.service.revision, assignedRevision + 1)
    }

    func testLegacyMigrationIsIdempotentAndClearsSourceOnlyAfterPersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ActionShortcutAssignmentStore(userDefaults: defaults)
        let reference = ActionReference(
            key: ActionKey(providerID: "mactools", actionID: "app.open-settings")
        )
        let binding = ShortcutBinding(keyCode: 12, modifiers: [.command, .option])
        var didPersistCount = 0

        XCTAssertTrue(
            store.migrateLegacyAppAssignments([(reference, binding)]) {
                didPersistCount += 1
            }
        )
        XCTAssertFalse(
            store.migrateLegacyAppAssignments([(reference, binding)]) {
                didPersistCount += 1
            }
        )
        XCTAssertEqual(didPersistCount, 1)
        XCTAssertEqual(store.assignments().map(\.reference), [reference])
        XCTAssertEqual(store.assignments().map(\.binding), [binding])
    }

    func testStoredActionReferenceAliasesConvergeWithoutDroppingBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ActionShortcutAssignmentStore(userDefaults: defaults)
        let key = ActionKey(providerID: "shortcut-tests", actionID: "migrated")
        let legacy = ActionReference(key: key, schemaVersion: 1)
        let current = ActionReference(key: key, schemaVersion: 2)
        let firstID = UUID()
        let secondID = UUID()
        let binding = ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        let secondBinding = ShortcutBinding(keyCode: 11, modifiers: [.command, .option])
        XCTAssertTrue(
            store.replaceAll([
                ActionShortcutAssignmentRecord(id: firstID, reference: legacy, binding: binding),
                ActionShortcutAssignmentRecord(id: secondID, reference: current, binding: secondBinding),
            ])
        )
        let registry = ActionRegistry()
        let provider = ShortcutActionTestProvider()
        let definition = ActionDefinition(
            key: key,
            parameterSchemaVersion: 2,
            title: "迁移操作",
            description: "测试迁移",
            systemImage: "bolt",
            externalInvocationPolicy: .allowed,
            capabilities: [.background, .foregroundInteractive]
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: current, title: "迁移操作")],
                availability: { _ in .available },
                migrate: { reference, version in
                    ActionReference(
                        key: reference.key,
                        schemaVersion: version,
                        parameters: reference.parameters
                    )
                },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let registrar = FakeCarbonHotKeyRegistrar()
        let service = ShortcutAssignmentService(
            registry: registry,
            store: store,
            shortcutManager: GlobalShortcutManager(registrar: registrar)
        )

        service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])

        XCTAssertEqual(service.assignments.map(\.id), [firstID, secondID])
        XCTAssertEqual(service.assignments.map(\.reference), [current, current])
        XCTAssertEqual(service.assignments.map(\.binding), [binding, secondBinding])
        XCTAssertEqual(service.settingsItems.map(\.state), [.registered, .registered])
        XCTAssertEqual(Set(registrar.registeredBindings), Set([binding, secondBinding]))

        let replacement = ShortcutBinding(keyCode: 12, modifiers: [.command, .shift])
        XCTAssertEqual(
            service.assign(replacement, to: current, assignmentID: secondID),
            .success
        )
        XCTAssertEqual(service.assignments.map(\.id), [firstID, secondID])
        XCTAssertEqual(service.assignments.map(\.binding), [binding, replacement])
        XCTAssertEqual(
            service.assign(binding, to: current, assignmentID: secondID),
            .failure(.conflict(ownerDescription: "迁移操作"))
        )

        XCTAssertTrue(service.clear(current, assignmentID: firstID))
        XCTAssertEqual(service.assignments.map(\.id), [secondID])
        XCTAssertEqual(service.assignments.map(\.binding), [replacement])
        XCTAssertEqual(service.settingsItems.map(\.id), [secondID])
    }

    private func makeHarness() throws -> ShortcutServiceHarness {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let registry = ActionRegistry()
        let provider = ShortcutActionTestProvider()
        let definitions = (1 ... 2).map { index in
            ActionDefinition(
                key: ActionKey(providerID: "shortcut-tests", actionID: "action-\(index)"),
                title: "操作 \(index)",
                description: "测试操作",
                systemImage: "bolt",
                externalInvocationPolicy: .allowed,
                capabilities: [.background, .foregroundInteractive]
            )
        }
        let entries = definitions.map {
            ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
        }
        registry.synchronize([
            ActionProviderRegistration(
                providerID: "shortcut-tests",
                identity: ObjectIdentifier(provider),
                definitions: definitions,
                catalogEntries: entries,
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let service = ShortcutAssignmentService(
            registry: registry,
            store: ActionShortcutAssignmentStore(userDefaults: defaults),
            shortcutManager: manager
        )
        service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        return ShortcutServiceHarness(
            defaults: defaults,
            registry: registry,
            registrar: registrar,
            manager: manager,
            service: service,
            references: entries.map(\.reference),
            bindings: [
                ShortcutBinding(keyCode: 10, modifiers: [.command, .option]),
                ShortcutBinding(keyCode: 11, modifiers: [.command, .shift]),
            ]
        )
    }
}

@MainActor
private final class ShortcutActionTestProvider {}

@MainActor
private struct ShortcutServiceHarness {
    let defaults: UserDefaults
    let registry: ActionRegistry
    let registrar: FakeCarbonHotKeyRegistrar
    let manager: GlobalShortcutManager
    let service: ShortcutAssignmentService
    let references: [ActionReference]
    let bindings: [ShortcutBinding]
}

@MainActor
final class FakeCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
    var failures: [ShortcutBinding: OSStatus] = [:]
    private(set) var registeredBindings: [ShortcutBinding] = []
    private(set) var unregisteredCount = 0

    func register(
        binding: ShortcutBinding,
        signature: OSType,
        carbonID: UInt32
    ) -> Result<EventHotKeyRef, GlobalShortcutRegistrationError> {
        if let status = failures[binding] {
            return .failure(.system(status))
        }
        registeredBindings.append(binding)
        return .success(OpaquePointer(bitPattern: Int(carbonID))!)
    }

    func unregister(_ reference: EventHotKeyRef) {
        unregisteredCount += 1
    }
}
