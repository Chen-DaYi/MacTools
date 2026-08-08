import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class AutomationRuntimeTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AutomationRuntimeTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSkippedRunSummaryRelocalizesAfterLanguageSwitchAndRelaunch() throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        PluginRuntimeLocalization.source.setPreference("zh-Hans")
        let fixture = try makeFixture()
        _ = try fixture.ruleStore.upsert(
            AutomationRule(
                name: "仅接电时",
                workflowID: fixture.workflow.id,
                trigger: .network(NetworkAutomationTrigger(status: .available)),
                conditions: [.power(PowerAutomationCondition(source: .adapter))]
            )
        ).get()
        fixture.snapshot.snapshotValue.powerSource = .battery
        fixture.runtime.start()
        fixture.providers[.network]?.emit(
            .network(status: .available, interface: .any, date: fixture.date)
        )
        let initialRun = try XCTUnwrap(fixture.workflowStore.history().first)
        XCTAssertNil(initialRun.summary)
        XCTAssertEqual(initialRun.automationSkippedSummary?.reason, .powerSourceMismatch)
        XCTAssertEqual(
            initialRun.localizedSummary,
            "规则“仅接电时”未运行：当前电源来源不匹配。"
        )

        PluginRuntimeLocalization.source.setPreference("en")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let englishRun = try XCTUnwrap(
            WorkflowStore(userDefaults: defaults).history().first
        )
        XCTAssertEqual(
            englishRun.localizedSummary,
            "Rule “仅接电时” did not run: The current power source does not match."
        )

        PluginRuntimeLocalization.source.setPreference("ar")
        let arabicRun = try XCTUnwrap(
            WorkflowStore(userDefaults: defaults).history().first
        )
        XCTAssertEqual(
            withoutBidirectionalIsolation(try XCTUnwrap(arabicRun.localizedSummary)),
            "القاعدة \"仅接电时\" ليست قيد التشغيل: مصدر الطاقة الحالي غير متطابق."
        )
    }

    func testEachTriggerProviderStartsSameWorkflowThroughGenericRuntime() throws {
        let fixture = try makeFixture()
        let date = fixture.date
        let display = AutomationDisplaySnapshot(identifier: "42", name: "Studio Display")
        let triggersAndEvents: [(AutomationTrigger, AutomationTriggerEvent)] = [
            (.schedule(ScheduleAutomationTrigger(hour: 9, minute: 30, weekdays: [2])), .schedule(date)),
            (.calendar(CalendarAutomationTrigger(phase: .starts, titleContains: "meeting")), .calendar(identifier: "event", title: "Team Meeting", calendarIdentifier: nil, phase: .starts, date: date)),
            (.application(ApplicationAutomationTrigger(event: .activates, bundleIdentifier: "com.example.editor")), .application(bundleIdentifier: "com.example.editor", event: .activates, date: date)),
            (.power(PowerAutomationTrigger(event: .adapterConnected)), .power(source: .adapter, batteryLevel: 80, event: .adapterConnected, date: date)),
            (.display(DisplayAutomationTrigger(event: .connected, displayIdentifier: "42")), .display(display, event: .connected, date: date)),
            (.network(NetworkAutomationTrigger(status: .available, interface: .wifi)), .network(status: .available, interface: .wifi, date: date)),
        ]
        for (index, pair) in triggersAndEvents.enumerated() {
            _ = try fixture.ruleStore.upsert(
                AutomationRule(
                    name: "规则 \(index)",
                    workflowID: fixture.workflow.id,
                    trigger: pair.0
                )
            ).get()
        }
        fixture.runtime.start()

        for (_, event) in triggersAndEvents {
            fixture.providers[event.kind]?.emit(event)
        }

        XCTAssertEqual(fixture.starter.starts.count, 6)
        XCTAssertTrue(fixture.starter.starts.allSatisfy { $0.workflowID == fixture.workflow.id })
        XCTAssertTrue(fixture.starter.starts.allSatisfy { $0.mode == .background })
        XCTAssertEqual(Set(fixture.starter.starts.compactMap(\.automaticTriggerKind)), Set(AutomationTriggerKind.allCases.map(\.rawValue)))
    }

    func testConditionFailureRecordsReasonWithoutBlockingManualStart() throws {
        let fixture = try makeFixture()
        let rule = try fixture.ruleStore.upsert(
            AutomationRule(
                name: "仅接电时",
                workflowID: fixture.workflow.id,
                trigger: .network(NetworkAutomationTrigger(status: .available)),
                conditions: [.power(PowerAutomationCondition(source: .adapter))]
            )
        ).get()
        fixture.snapshot.snapshotValue.powerSource = .battery
        fixture.runtime.start()

        fixture.providers[.network]?.emit(
            .network(status: .available, interface: .any, date: fixture.date)
        )

        XCTAssertTrue(fixture.starter.starts.isEmpty)
        let skipped = try XCTUnwrap(fixture.workflowStore.history().first)
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertEqual(skipped.source, .automatic(ruleID: rule.id, triggerKind: "network"))
        XCTAssertTrue(
            skipped.localizedSummary?.contains(
                FeatureL10n.string("当前电源来源不匹配。").dropLast()
            ) == true
        )

        _ = fixture.starter.makeExecutionHandle(
            workflowID: fixture.workflow.id,
            source: .manual,
            mode: .foreground
        )
        XCTAssertEqual(fixture.starter.starts.last?.source, .manual)
    }

    func testDuplicateEventsAreSuppressedAndOverlappingRunsAreSkipped() throws {
        let fixture = try makeFixture(completesImmediately: false)
        _ = try fixture.ruleStore.upsert(
            AutomationRule(
                workflowID: fixture.workflow.id,
                trigger: .network(NetworkAutomationTrigger(status: .available))
            )
        ).get()
        fixture.runtime.start()
        let event = AutomationTriggerEvent.network(
            status: .available,
            interface: .any,
            date: fixture.date
        )

        fixture.providers[.network]?.emit(event)
        fixture.providers[.network]?.emit(event)
        fixture.providers[.network]?.emit(
            .network(status: .available, interface: .any, date: fixture.date.addingTimeInterval(3))
        )

        XCTAssertEqual(fixture.starter.starts.count, 1)
        XCTAssertTrue(
            fixture.workflowStore.history().first?.localizedSummary?.contains(
                FeatureL10n.string("该规则的上一次运行尚未结束。").dropLast()
            ) == true
        )
    }

    func testCalendarEventRunsOnlyTheRuleForItsScheduledOffset() throws {
        let fixture = try makeFixture()
        let matchingRule = try fixture.ruleStore.upsert(
            AutomationRule(
                name: "Ten Minutes Before",
                workflowID: fixture.workflow.id,
                trigger: .calendar(CalendarAutomationTrigger(
                    phase: .starts,
                    calendarIdentifier: "work",
                    titleContains: "planning",
                    offsetMinutes: -10
                ))
            )
        ).get()
        _ = try fixture.ruleStore.upsert(
            AutomationRule(
                name: "Ten Minutes After",
                workflowID: fixture.workflow.id,
                trigger: .calendar(CalendarAutomationTrigger(
                    phase: .starts,
                    calendarIdentifier: "work",
                    titleContains: "planning",
                    offsetMinutes: 10
                ))
            )
        ).get()
        fixture.runtime.start()

        fixture.providers[.calendar]?.emit(.calendar(
            identifier: "planning-event",
            title: "Planning",
            calendarIdentifier: "work",
            phase: .starts,
            offsetMinutes: -10,
            date: fixture.date
        ))

        XCTAssertEqual(fixture.starter.starts.count, 1)
        XCTAssertEqual(
            fixture.starter.starts.first?.source,
            .automatic(ruleID: matchingRule.id, triggerKind: AutomationTriggerKind.calendar.rawValue)
        )
    }

    private func withoutBidirectionalIsolation(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{2068}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "")
    }

    func testProviderAvailabilityAndRefreshAreInspectable() throws {
        let fixture = try makeFixture()
        let schedule = try XCTUnwrap(fixture.providers[.schedule])
        schedule.availability = .unavailable("系统日历不可用。")
        _ = try fixture.ruleStore.upsert(
            AutomationRule(workflowID: fixture.workflow.id, trigger: .schedule(ScheduleAutomationTrigger()))
        ).get()

        fixture.runtime.start()

        XCTAssertEqual(fixture.runtime.availability(for: .schedule), .unavailable("系统日历不可用。"))
        XCTAssertEqual(schedule.refreshedRules.count, 1)
        XCTAssertEqual(fixture.runtime.availability(for: .calendar), .available)
    }

    func testBackgroundUnsupportedWorkflowRecordsSpecificSkipReason() throws {
        let fixture = try makeFixture(startError: .backgroundExecutionUnsupported)
        let rule = try fixture.ruleStore.upsert(AutomationRule(
            workflowID: fixture.workflow.id,
            trigger: .network(NetworkAutomationTrigger(status: .available))
        )).get()
        fixture.runtime.start()

        fixture.providers[.network]?.emit(
            .network(status: .available, interface: .any, date: fixture.date)
        )

        let run = try XCTUnwrap(fixture.workflowStore.history().first)
        XCTAssertEqual(run.source, .automatic(ruleID: rule.id, triggerKind: "network"))
        XCTAssertEqual(
            run.automationSkippedSummary?.reason,
            .backgroundExecutionUnsupported
        )
    }

    private func makeFixture(
        completesImmediately: Bool = true,
        startError: WorkflowStartError? = nil
    ) throws -> RuntimeFixture {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let workflowStore = WorkflowStore(userDefaults: defaults)
        let workflow = try workflowStore.create(name: "演示").get()
        let ruleStore = AutomationRuleStore(userDefaults: defaults)
        let starter = FakeWorkflowStarter(
            completesImmediately: completesImmediately,
            startError: startError
        )
        let date = Date(timeIntervalSince1970: 1_775_000_200)
        let snapshot = FakeAutomationSnapshotProvider(
            AutomationEnvironmentSnapshot(
                date: date,
                frontmostApplicationBundleIdentifier: "com.example.editor",
                batteryLevel: 80,
                powerSource: .adapter,
                connectedDisplays: [AutomationDisplaySnapshot(identifier: "42", name: "Studio Display")],
                networkStatus: .available,
                networkInterface: .wifi
            )
        )
        let providers = Dictionary(
            uniqueKeysWithValues: AutomationTriggerKind.allCases.map {
                ($0, FakeAutomationTriggerProvider(kind: $0))
            }
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: 2026, month: 8, day: 3, hour: 9, minute: 30)
        let matchingDate = calendar.date(from: components)!
        snapshot.snapshotValue.date = matchingDate
        let runtime = AutomationRuntime(
            ruleStore: ruleStore,
            workflowStore: workflowStore,
            workflowStarter: starter,
            snapshotProvider: snapshot,
            providers: Array(providers.values),
            evaluator: AutomationRuleEvaluator(calendar: calendar),
            now: { matchingDate }
        )
        return RuntimeFixture(
            workflowStore: workflowStore,
            ruleStore: ruleStore,
            workflow: workflow,
            starter: starter,
            snapshot: snapshot,
            providers: providers,
            runtime: runtime,
            date: matchingDate
        )
    }
}

@MainActor
private struct RuntimeFixture {
    let workflowStore: WorkflowStore
    let ruleStore: AutomationRuleStore
    let workflow: WorkflowDefinition
    let starter: FakeWorkflowStarter
    let snapshot: FakeAutomationSnapshotProvider
    let providers: [AutomationTriggerKind: FakeAutomationTriggerProvider]
    let runtime: AutomationRuntime
    let date: Date
}

@MainActor
private final class FakeAutomationTriggerProvider: AutomationTriggerProviding {
    let kind: AutomationTriggerKind
    var availability: AutomationTriggerAvailability = .available
    var refreshedRules: [AutomationRule] = []
    private var handler: (@MainActor (AutomationTriggerEvent) -> Void)?

    init(kind: AutomationTriggerKind) {
        self.kind = kind
    }

    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func refresh(rules: [AutomationRule]) {
        refreshedRules = rules
    }

    func emit(_ event: AutomationTriggerEvent) {
        handler?(event)
    }
}

@MainActor
private final class FakeAutomationSnapshotProvider: AutomationEnvironmentSnapshotProviding {
    var snapshotValue: AutomationEnvironmentSnapshot

    init(_ snapshot: AutomationEnvironmentSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot(at date: Date) -> AutomationEnvironmentSnapshot {
        var value = snapshotValue
        value.date = date
        return value
    }
}

@MainActor
private final class FakeWorkflowStarter: WorkflowStarting {
    struct Start {
        let workflowID: UUID
        let source: WorkflowRunSource
        let mode: ActionExecutionMode

        var automaticTriggerKind: String? {
            guard case let .automatic(_, triggerKind) = source else { return nil }
            return triggerKind
        }
    }

    private let completesImmediately: Bool
    private let startError: WorkflowStartError?
    private(set) var starts: [Start] = []

    init(completesImmediately: Bool, startError: WorkflowStartError? = nil) {
        self.completesImmediately = completesImmediately
        self.startError = startError
    }

    func makeExecutionHandle(
        workflowID: UUID,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) -> Result<WorkflowExecutionHandle, WorkflowStartError> {
        if let startError {
            return .failure(startError)
        }
        starts.append(Start(workflowID: workflowID, source: source, mode: mode))
        let handle = ActionExecutionHandle(operation: { [completesImmediately] in
            if !completesImmediately {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            }
            return .succeeded()
        })
        return .success(WorkflowExecutionHandle(runID: UUID(), actionHandle: handle))
    }
}
