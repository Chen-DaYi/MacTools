import XCTest
@testable import MacSettingsPlugin

@MainActor
final class MacSettingsControllerTests: XCTestCase {
    func testVerifiedApplyUpdatesOnlyOneRowAndRecordsBoundedHistory() async {
        let firstAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let secondAdapter = DeterministicSystemSettingAdapter(value: .boolean(true))
        let first = makeTestRecord(id: "first", title: "First", adapter: firstAdapter)
        let second = makeTestRecord(id: "second", title: "Second", adapter: secondAdapter)
        let historyStore = InMemorySystemSettingChangeHistoryStore()
        let controller = MacSettingsController(
            catalog: makeTestCatalog([first, second]),
            storage: MacSettingsTestStorage(),
            historyStore: historyStore,
            profileStore: InMemorySystemSettingsProfileStore()
        )

        await controller.refresh(first)
        await controller.refresh(second)
        let applied = await controller.applyAndWait(.boolean(true), to: first)
        XCTAssertTrue(applied)

        XCTAssertEqual(controller.rowStates[first.id]?.value, .boolean(true))
        XCTAssertEqual(controller.rowStates[first.id]?.verification, .verified)
        XCTAssertEqual(controller.rowStates[second.id]?.value, .boolean(true))
        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.history.first?.previousValue, .boolean(false))
        XCTAssertEqual(controller.history.first?.newValue, .boolean(true))
    }

    func testVerificationMismatchIsVisibleAndNotRecordedAsSuccess() async {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        adapter.queuedVerificationOverrides = [.mismatch(actual: .boolean(false))]
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        let applied = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertFalse(applied)
        XCTAssertEqual(controller.rowStates[record.id]?.verification, .failed)
        XCTAssertEqual(controller.rowStates[record.id]?.value, .boolean(false))
        XCTAssertEqual(adapter.rollbackValues, [.boolean(false)])
        XCTAssertNotNil(controller.rowStates[record.id]?.errorMessage)
        XCTAssertTrue(controller.needsAttention(record.id))
        XCTAssertTrue(controller.history.isEmpty)
    }

    func testVerificationUnavailableIsRecordedAsUnverified() async {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        adapter.verificationOverride = .unavailable
        let record = makeTestRecord(id: "unverified", title: "Unverified", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        let applied = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertTrue(applied)
        XCTAssertEqual(controller.rowStates[record.id]?.verification, .unverified)
        XCTAssertEqual(controller.history.first?.verification, .unverified)
    }

    func testFavoritesPreserveOrderingAndRemainControllable() async {
        let first = makeTestRecord(
            id: "first",
            title: "First",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let second = makeTestRecord(
            id: "second",
            title: "Second",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([first, second]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        controller.toggleFavorite(second.id)
        controller.toggleFavorite(first.id)
        controller.destination = .favorites
        XCTAssertEqual(controller.visibleRecords.map(\.id), [second.id, first.id])

        controller.moveFavorites(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(controller.visibleRecords.map(\.id), [first.id, second.id])
        controller.moveFavorite(second.id, by: -1)
        XCTAssertEqual(controller.visibleRecords.map(\.id), [second.id, first.id])
        let applied = await controller.applyAndWait(.boolean(true), to: first)
        XCTAssertTrue(applied)
    }

    func testNeedsAttentionContainsOnlyActionableStates() {
        let direct = makeTestRecord(
            id: "direct",
            title: "Direct",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let guided = makeTestRecord(
            id: "guided",
            title: "Guided",
            executionClass: .guidedManual,
            adapter: UnavailableSystemSettingAdapter(message: "Manual")
        )
        let provider = makeTestRecord(
            id: "provider",
            title: "Provider",
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: "missing"),
            adapter: UnavailableSystemSettingAdapter(message: "Missing")
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([direct, guided, provider]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        XCTAssertFalse(controller.needsAttention(direct.id))
        XCTAssertFalse(controller.needsAttention(guided.id))
        XCTAssertTrue(controller.needsAttention(provider.id))
        controller.destination = .attention
        XCTAssertEqual(controller.visibleRecords.map(\.id), [provider.id])
    }

    func testHistoryStoreBoundsCountAndAge() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let recent = (0 ..< 250).map { offset in
            SystemSettingChange(
                settingID: SystemSettingID(rawValue: "setting.\(offset)"),
                settingTitle: "Setting",
                previousValue: .boolean(false),
                newValue: .boolean(true),
                date: now.addingTimeInterval(-Double(offset)),
                verification: .verified,
                canRollback: true
            )
        }
        let old = SystemSettingChange(
            settingID: "old",
            settingTitle: "Old",
            previousValue: .boolean(false),
            newValue: .boolean(true),
            date: now.addingTimeInterval(-(SystemSettingChangeHistoryStore.maximumAge + 1)),
            verification: .verified,
            canRollback: true
        )

        let bounded = SystemSettingChangeHistoryStore.bounded(recent + [old], referenceDate: now)
        XCTAssertEqual(bounded.count, SystemSettingChangeHistoryStore.maximumCount)
        XCTAssertFalse(bounded.contains { $0.id == old.id })
    }
}
