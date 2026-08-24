import XCTest
@testable import MacSettingsPlugin

@MainActor
final class SystemSettingsProfileTests: XCTestCase {
    func testBooleanOffIsDistinctFromExclusionAndChangingValueIncludes() {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(true))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let catalog = makeTestCatalog([record])
        var draft = SystemSettingsProfileDraft(
            name: "Test",
            profileDescription: "",
            items: [.init(settingID: record.id, isIncluded: false, desiredValue: .boolean(false))]
        )

        XCTAssertTrue(draft.makeProfile(catalog: catalog).entries.isEmpty)
        draft.setDesiredValue(.boolean(false), for: record.id)
        let profile = draft.makeProfile(catalog: catalog)
        XCTAssertEqual(profile.entries.count, 1)
        XCTAssertEqual(profile.entries.first?.desiredValue, .boolean(false))

        draft.setIncluded(false, for: record.id)
        XCTAssertTrue(draft.makeProfile(catalog: catalog).entries.isEmpty)
        XCTAssertEqual(adapter.value, .boolean(true), "Editing inclusion must not touch the current Mac")
    }

    func testImportPreservesUnknownIDsButNeverPlansExecution() throws {
        let known = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([known])
        let profile = SystemSettingsProfile(
            name: "Imported",
            entries: [
                .init(settingID: "future.setting", desiredValue: .boolean(true), category: nil),
            ]
        )
        let data = try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
        let decoded = try SystemSettingsProfileCodec.decode(data, catalog: catalog)

        XCTAssertEqual(decoded.0.entries.first?.settingID, "future.setting")
        XCTAssertEqual(decoded.1.warnings, [.unknownSetting("future.setting")])
        let plan = SystemSettingsProfilePlanner.makePlan(
            profile: decoded.0,
            catalog: catalog,
            currentValues: [:],
            availability: [:]
        )
        XCTAssertEqual(plan.items.first?.status, .unknownSetting)
        XCTAssertFalse(plan.items.first?.isSelected ?? true)
    }

    func testImportRejectsOversizedFilesAndArbitraryCommandFields() throws {
        let record = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([record])
        XCTAssertThrowsError(try SystemSettingsProfileCodec.decode(
            Data(repeating: 0, count: SystemSettingsProfileCodec.maximumFileSize + 1),
            catalog: catalog
        )) {
            XCTAssertEqual($0 as? SystemSettingsProfileCodecError, .fileTooLarge)
        }

        let profile = SystemSettingsProfile(
            name: "Safe",
            entries: [.init(settingID: record.id, desiredValue: .boolean(true), category: .finder)]
        )
        let valid = try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["command"] = "rm -rf /"
        let malicious = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try SystemSettingsProfileCodec.decode(malicious, catalog: catalog)) {
            XCTAssertEqual($0 as? SystemSettingsProfileCodecError, .malformedFile)
        }
    }

    func testPlannerSkipsMatchesAndSupportsPerChangeSelection() {
        let first = makeTestRecord(
            id: "first",
            title: "First",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(true))
        )
        let second = makeTestRecord(
            id: "second",
            title: "Second",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([first, second])
        let profile = SystemSettingsProfile(
            name: "Plan",
            entries: [
                .init(settingID: first.id, desiredValue: .boolean(true), category: .finder),
                .init(settingID: second.id, desiredValue: .boolean(true), category: .finder),
            ]
        )
        let plan = SystemSettingsProfilePlanner.makePlan(
            profile: profile,
            catalog: catalog,
            currentValues: [first.id: .boolean(true), second.id: .boolean(false)],
            availability: [first.id: .available, second.id: .available]
        )

        XCTAssertEqual(plan.items[0].status, .alreadyMatches)
        XCTAssertFalse(plan.items[0].isSelected)
        XCTAssertEqual(plan.items[1].status, .ready)
        XCTAssertTrue(plan.items[1].isSelected)
        XCTAssertFalse(plan.selecting([]).items[1].isSelected)
        XCTAssertTrue(plan.items[1].isSelected, "Selecting a plan must not mutate the saved immutable plan")
    }

    func testApplyReportsPartialResultsAndRollsBackVerificationFailure() async {
        let successfulAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let mismatchAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        mismatchAdapter.queuedVerificationOverrides = [.mismatch(actual: .boolean(false))]
        let successful = makeTestRecord(id: "success", title: "Success", adapter: successfulAdapter)
        let mismatch = makeTestRecord(id: "mismatch", title: "Mismatch", adapter: mismatchAdapter)
        let catalog = makeTestCatalog([successful, mismatch])
        let plan = SystemSettingsProfileApplyPlan(
            profileID: UUID(),
            profileName: "Apply",
            items: [
                .init(
                    settingID: successful.id,
                    title: successful.definition.title,
                    currentValue: .boolean(false),
                    desiredValue: .boolean(true),
                    status: .ready,
                    isSelected: true
                ),
                .init(
                    settingID: mismatch.id,
                    title: mismatch.definition.title,
                    currentValue: .boolean(false),
                    desiredValue: .boolean(true),
                    status: .ready,
                    isSelected: true
                ),
            ]
        )

        let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: plan)
        XCTAssertEqual(report.results.map(\.kind), [.appliedAndVerified, .failedAndRolledBack])
        XCTAssertTrue(report.hasPartialSuccess)
        XCTAssertEqual(mismatchAdapter.rollbackValues, [.boolean(false)])
        XCTAssertEqual(report.rollbackPoint.entries.count, 2)
    }

    func testExportContainsNoSensitiveOrExecutableData() throws {
        let record = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([record])
        let profile = SystemSettingsProfile(
            name: "Portable",
            entries: [.init(settingID: record.id, desiredValue: .boolean(true), category: .finder)]
        )
        let text = String(decoding: try SystemSettingsProfileCodec.encode(profile, catalog: catalog), as: UTF8.self)

        XCTAssertTrue(text.contains("known"))
        XCTAssertFalse(text.contains("command"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("preferenceDomain"))
    }

    func testProfilesRejectMachineSpecificAndSensitiveCatalogValues() {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let deviceSpecific = makeTestRecord(
            id: "device-specific",
            title: "Device",
            portability: .deviceSpecific,
            adapter: adapter
        )
        let sensitive = makeTestRecord(
            id: "sensitive",
            title: "Sensitive",
            portability: .prohibited,
            isSensitive: true,
            adapter: adapter
        )
        let catalog = makeTestCatalog([deviceSpecific, sensitive])
        let profile = SystemSettingsProfile(
            name: "Unsafe",
            entries: [
                .init(settingID: deviceSpecific.id, desiredValue: .boolean(true), category: .finder),
                .init(settingID: sensitive.id, desiredValue: .boolean(true), category: .finder),
            ]
        )

        let validation = SystemSettingsProfileCodec.validate(profile, catalog: catalog)

        XCTAssertTrue(validation.errors.contains(.nonPortableSetting(deviceSpecific.id)))
        XCTAssertTrue(validation.errors.contains(.sensitiveSetting(sensitive.id)))
    }
}
