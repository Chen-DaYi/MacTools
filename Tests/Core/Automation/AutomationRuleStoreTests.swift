import XCTest
@testable import MacTools

@MainActor
final class AutomationRuleStoreTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AutomationRuleStoreTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRulesSupportIndependentCRUDAndRetainMissingWorkflowReferences() throws {
        let store = try makeStore()
        let missingWorkflowID = UUID()
        let created = try store.create(workflowID: missingWorkflowID).get()
        var updated = created
        updated.name = "外接显示器"
        updated.trigger = .display(
            DisplayAutomationTrigger(
                event: .connected,
                displayIdentifier: "display-1",
                displayNameContains: "Studio"
            )
        )
        updated.conditions = [
            .power(PowerAutomationCondition(source: .adapter))
        ]

        let saved = try store.upsert(updated).get()
        let duplicate = try store.duplicate(id: saved.id).get()

        XCTAssertEqual(saved.workflowID, missingWorkflowID)
        XCTAssertEqual(duplicate.workflowID, missingWorkflowID)
        XCTAssertEqual(duplicate.trigger, saved.trigger)
        XCTAssertNotEqual(duplicate.id, saved.id)
        XCTAssertTrue(store.delete(id: saved.id))
        XCTAssertEqual(store.rules().map(\.id), [duplicate.id])
    }

    func testCorruptAndInvalidRulePayloadsFailClosedWithoutDeletingBytes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = AutomationRuleStore(userDefaults: defaults)
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "automation.rules.v1")

        XCTAssertTrue(store.rules().isEmpty)
        XCTAssertEqual(store.loadError, "invalid-rule-payload")
        XCTAssertEqual(defaults.data(forKey: "automation.rules.v1"), corrupt)

        var invalid = AutomationRule(workflowID: UUID())
        invalid.trigger = .application(ApplicationAutomationTrigger(bundleIdentifier: ""))
        XCTAssertEqual(store.upsert(invalid), .failure(.invalidRule("rule-fields")))
    }

    func testEveryTriggerAndConditionShapeRoundTrips() throws {
        let store = try makeStore()
        let workflowID = UUID()
        let triggers: [AutomationTrigger] = [
            .schedule(ScheduleAutomationTrigger(hour: 8, minute: 30, weekdays: [2, 4, 6])),
            .calendar(CalendarAutomationTrigger(phase: .starts, calendarIdentifier: "work", titleContains: "standup", offsetMinutes: -10)),
            .application(ApplicationAutomationTrigger(event: .launches, bundleIdentifier: "com.example.editor")),
            .power(PowerAutomationTrigger(event: .batteryAtOrBelow, batteryLevel: 25)),
            .display(DisplayAutomationTrigger(event: .connected, displayIdentifier: "42", displayNameContains: "Studio")),
            .network(NetworkAutomationTrigger(status: .available, interface: .wifi)),
        ]
        let conditions: [AutomationCondition] = [
            .frontmostApplication(FrontmostApplicationCondition(bundleIdentifier: "com.example.editor")),
            .power(PowerAutomationCondition(source: .adapter, minimumBatteryLevel: 40, maximumBatteryLevel: 90)),
            .connectedDisplay(ConnectedDisplayCondition(displayIdentifier: "42", displayNameContains: "Studio")),
            .timeRange(TimeRangeAutomationCondition(startMinute: 480, endMinute: 1_020, weekdays: [2, 3, 4, 5, 6])),
            .network(NetworkAutomationCondition(status: .available, interface: .wifi)),
        ]

        for (index, trigger) in triggers.enumerated() {
            _ = try store.upsert(
                AutomationRule(
                    name: "规则 \(index)",
                    workflowID: workflowID,
                    trigger: trigger,
                    conditions: conditions
                )
            ).get()
        }

        XCTAssertEqual(store.rules().map(\.trigger), triggers)
        XCTAssertTrue(store.rules().allSatisfy { $0.conditions == conditions })
    }

    private func makeStore() throws -> AutomationRuleStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AutomationRuleStore(userDefaults: defaults)
    }
}
