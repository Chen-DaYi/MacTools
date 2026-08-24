import XCTest
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class SystemSettingCatalogTests: XCTestCase {
    func testBuiltInCatalogIsCuratedAndValid() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }

        XCTAssertEqual(catalog.records.count, 48)
        XCTAssertEqual(Set(catalog.records.map(\.id)).count, catalog.records.count)
        XCTAssertTrue(catalog.records.allSatisfy { $0.definition.schema.isValid })
        XCTAssertTrue(catalog.records.allSatisfy { !$0.definition.searchTerms.isEmpty })
        XCTAssertTrue(catalog.records.contains { $0.definition.executionClass == .existingPluginProvider })
        XCTAssertTrue(catalog.records.contains { $0.definition.executionClass == .guidedManual })

        XCTAssertEqual(
            catalog["accessibility.three-finger-drag"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.pointer-size"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.pointer-size"]?.definition.requirements.requiredPermissionID,
            MacSettingsPermission.fullDiskAccess
        )
        XCTAssertEqual(
            catalog["accessibility.keyboard-zoom"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.scroll-zoom"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.scroll-zoom-modifier"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["finder.show-path-bar"]?.definition.executionClass,
            .directRequiresRestart
        )
        XCTAssertEqual(
            catalog["finder.search-scope"]?.definition.executionClass,
            .directAppliesNextUse
        )
        XCTAssertEqual(
            catalog["screenshots.format"]?.definition.executionClass,
            .directAppliesNextUse
        )
        XCTAssertEqual(
            catalog["input.mouse-tracking-speed"]?.definition.executionClass,
            .directRequiresLogout
        )
        XCTAssertEqual(
            catalog["input.scroll-speed"]?.definition.executionClass,
            .guidedManual
        )
        XCTAssertEqual(catalog["dock.size"]?.definition.executionClass, .directVerified)
        XCTAssertEqual(
            catalog["finder.warn-empty-trash"]?.definition.executionClass,
            .directAppliesNextUse
        )
        XCTAssertEqual(
            catalog["display.true-tone"]?.definition.executionClass,
            .existingPluginProvider
        )
        XCTAssertEqual(
            catalog["display.night-shift"]?.definition.executionClass,
            .existingPluginProvider
        )
        XCTAssertEqual(Set(catalog.records.map(\.definition.category)), Set(SystemSettingCategory.allCases))
        XCTAssertTrue(catalog["accessibility.three-finger-drag"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.pointer-size"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.keyboard-zoom"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.scroll-zoom"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.scroll-zoom-modifier"]?.definition.isProfileEligible == true)
    }

    func testDisplayProvidersReadLiveActionStateAndWriteExplicitDesiredValue() async throws {
        var executedReference: ActionReference?
        let context = PluginActionExecutionHostContext(
            item: { reference in
                guard reference.key.providerID == "display-true-color",
                      reference.key.actionID == "toggle" else { return nil }
                return ActionSurfaceCatalogItem(
                    reference: reference,
                    title: "True Tone",
                    subtitle: nil,
                    ownerTitle: "Display",
                    systemImage: "display",
                    availability: .available,
                    isSafe: true,
                    presentationState: .active
                )
            },
            execute: { reference, _ in
                executedReference = reference
                return .succeeded(message: nil)
            }
        )
        let catalog = try MacSettingsCatalogFactory.make { context }
        let record = try XCTUnwrap(catalog["display.true-tone"])

        let currentValue = try await record.adapter.read()
        XCTAssertEqual(currentValue, .boolean(true))
        try await record.adapter.apply(.boolean(false))
        XCTAssertEqual(executedReference?.key.providerID, "display-true-color")
        XCTAssertEqual(executedReference?.key.actionID, "set-enabled")
        XCTAssertEqual(executedReference?.parameters["enabled"], .boolean(false))
    }

    func testNaturalLanguageSearchExamplesRemainDirectResults() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        let expectations: [(String, SystemSettingID)] = [
            ("drag window trackpad", "accessibility.three-finger-drag"),
            ("large cursor", "accessibility.pointer-size"),
            ("show extension", "finder.show-all-extensions"),
            ("dock disappear", "dock.auto-hide"),
            ("screenshot jpg", "screenshots.format"),
            ("zoom keyboard", "accessibility.keyboard-zoom"),
            ("scroll gesture zoom", "accessibility.scroll-zoom"),
            ("scroll zoom modifier", "accessibility.scroll-zoom-modifier"),
        ]

        for (query, expectedID) in expectations {
            XCTAssertEqual(catalog.search(query).first?.id, expectedID, "Query: \(query)")
        }
    }

    func testCatalogRejectsDuplicateIDsAndInvalidDefaults() {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let first = makeTestRecord(id: "duplicate", title: "First", adapter: adapter)
        let second = makeTestRecord(id: "duplicate", title: "Second", adapter: adapter)
        XCTAssertThrowsError(try SystemSettingCatalog(records: [first, second])) {
            XCTAssertEqual($0 as? SystemSettingCatalogValidationError, .duplicateID("duplicate"))
        }

        let invalid = makeTestRecord(
            id: "invalid",
            title: "Invalid",
            schema: .boolean,
            defaultValue: .integer(1),
            adapter: adapter
        )
        XCTAssertThrowsError(try SystemSettingCatalog(records: [invalid])) {
            XCTAssertEqual($0 as? SystemSettingCatalogValidationError, .invalidDefaultValue("invalid"))
        }
    }

    func testCompatibilityDistinguishesEveryRequirementState() {
        let environment = SystemSettingEnvironment(
            systemVersion: .init(14),
            availableHardware: [],
            grantedPermissionIDs: [],
            availableProviderIDs: []
        )
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let hardware = makeTestRecord(
            id: "hardware",
            title: "Hardware",
            requirements: .init(requiredHardware: "trackpad"),
            adapter: adapter
        )
        let permission = makeTestRecord(
            id: "permission",
            title: "Permission",
            requirements: .init(requiredPermissionID: "accessibility"),
            adapter: adapter
        )
        let provider = makeTestRecord(
            id: "provider",
            title: "Provider",
            requirements: .init(existingProviderID: "appearance"),
            adapter: adapter
        )
        let managed = makeTestRecord(
            id: "managed",
            title: "Managed",
            executionClass: .managedOnly,
            adapter: adapter
        )

        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: hardware.definition, environment: environment),
            .hardwareUnavailable("trackpad")
        )
        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: permission.definition, environment: environment),
            .permissionMissing("accessibility")
        )
        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: provider.definition, environment: environment),
            .providerUnavailable("appearance")
        )
        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: managed.definition, environment: environment),
            .managedOnly
        )
    }
}
