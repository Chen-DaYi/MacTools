import CoreAudio
import Foundation

private enum FixtureError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case unsafeDomain(String)
    case encoding(String)

    var description: String {
        switch self {
        case let .invalidArguments(message), let .encoding(message):
            return message
        case let .unsafeDomain(domain):
            return "Refusing to clear non-test preferences domain: \(domain)"
        }
    }
}

private struct ActionKey: Codable, Hashable {
    let providerID: String
    let actionID: String
}

private enum ActionParameterValue: Codable, Hashable {
    case boolean(Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case boolean
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

private struct ActionParameterEntry: Codable, Hashable {
    let name: String
    let value: ActionParameterValue
}

private struct ActionReference: Codable, Hashable {
    let key: ActionKey
    let schemaVersion: Int
    let parameters: [ActionParameterEntry]

    init(
        providerID: String,
        actionID: String,
        booleanParameters: [String: Bool] = [:]
    ) {
        key = ActionKey(providerID: providerID, actionID: actionID)
        schemaVersion = 1
        parameters = booleanParameters
            .map { ActionParameterEntry(name: $0.key, value: .boolean($0.value)) }
            .sorted { $0.name < $1.name }
    }
}

private struct ShortcutBinding: Codable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt8
}

private struct ShortcutAssignment: Codable, Hashable {
    let id: UUID
    let reference: ActionReference
    let binding: ShortcutBinding
}

private struct ShortcutPayload: Codable {
    let version: Int
    var assignments: [ShortcutAssignment]
}

private struct WorkflowStep: Codable {
    let id: UUID
    let reference: ActionReference
    let label: String?
    let delaySeconds: Double
    let errorPolicy: String
}

private struct WorkflowDefinition: Codable {
    let formatVersion: Int
    let id: UUID
    let name: String
    let systemImage: String
    let isEnabled: Bool
    let steps: [WorkflowStep]
    let createdAt: Date
    let updatedAt: Date
}

private struct WorkflowEnvelope: Codable {
    let formatVersion: Int
    let workflows: [WorkflowDefinition]
}

private enum ApplicationAutomationEvent: String, Codable {
    case activates
}

private struct ApplicationAutomationTrigger: Codable {
    let event: ApplicationAutomationEvent
    let bundleIdentifier: String
}

private enum AutomationTrigger: Codable {
    case application(ApplicationAutomationTrigger)
}

private struct FrontmostApplicationCondition: Codable {
    let bundleIdentifier: String
    let isExcluded: Bool
}

private enum AutomationCondition: Codable {
    case frontmostApplication(FrontmostApplicationCondition)
}

private struct AutomationRule: Codable {
    let formatVersion: Int
    let id: UUID
    let name: String
    let workflowID: UUID
    let isEnabled: Bool
    let trigger: AutomationTrigger
    let conditions: [AutomationCondition]
    let createdAt: Date
    let updatedAt: Date
}

private struct AutomationRuleEnvelope: Codable {
    let formatVersion: Int
    let rules: [AutomationRule]
}

private struct ActionGridEntry: Codable {
    let id: UUID
    let reference: ActionReference
    let customTitle: String?
}

private struct ActionGridEnvelope: Codable {
    let formatVersion: Int
    let entries: [ActionGridEntry]
}

private struct AuditReport: Codable {
    let bundleIdentifier: String
    let fixtureVersion: Int
    let valid: Bool
    let shortcutCount: Int
    let hasOpenSettingsShortcut: Bool
    let hasActionGridShortcut: Bool
    let hasDashboardShortcut: Bool
    let hasWorkflowShortcut: Bool
    let workflowCount: Int
    let workflowNames: [String]
    let workflowStepCounts: [String: Int]
    let hasDisplaySleepWorkflowStep: Bool
    let workflowName: String?
    let workflowStepCount: Int
    let automationWorkflowName: String?
    let automationWorkflowStepCount: Int
    let automationWorkflowIsIdempotent: Bool
    let systemMuteValue: Bool?
    let systemMuteStatePreserved: Bool
    let ruleCount: Int
    let ruleNames: [String]
    let calculatorRuleEnabled: Bool
    let calculatorSkipRuleEnabled: Bool
    let textEditRuleEnabled: Bool
    let actionGridEntryCount: Int
    let actionGridActionIDs: [String]
    let actionGridReferences: [String]
    let hasUnavailableGridEntry: Bool
    let language: String?
    let appearance: String?
    let workflowHistoryCount: Int
    let latestWorkflowStatus: String?
    let latestWorkflowSource: String?
}

private enum Fixture {
    static let version = 4
    static let markerKey = "mactools.e2e.fixture-version"
    static let shortcutKey = "action-shortcuts.assignments"
    static let workflowKey = "automation.workflows.v1"
    static let ruleKey = "automation.rules.v1"
    static let historyKey = "automation.history.v1"
    static let actionGridKey = "plugin.action-grid.layout.v1"
    static let languageKey = "app.languagePreference"
    static let appleLanguagesKey = "AppleLanguages"
    static let appearanceKey = "app.appearancePreference"

    static let workflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000247")!
    static let automationWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000248")!
    static let continueWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000260")!
    static let stopWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000261")!
    static let delayWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000262")!
    static let ruleID = UUID(uuidString: "00000000-0000-4000-8000-000000000249")!
    static let calculatorSkipRuleID = UUID(uuidString: "00000000-0000-4000-8000-000000000280")!
    static let textEditRuleID = UUID(uuidString: "00000000-0000-4000-8000-000000000281")!
    static let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static let openSettings = ActionReference(
        providerID: "mactools",
        actionID: "app.open-settings"
    )
    static let toggleDashboard = ActionReference(
        providerID: "mactools",
        actionID: "app.toggle-dashboard"
    )
    static let toggleFeaturePanel = ActionReference(
        providerID: "mactools",
        actionID: "app.toggle-feature-panel"
    )
    static let showActionGrid = ActionReference(
        providerID: "action-grid",
        actionID: "show"
    )
    static let toggleLaunchpad = ActionReference(
        providerID: "launchpad",
        actionID: "toggleLaunchpad"
    )
    static let missingAction = ActionReference(
        providerID: "e2e-missing-provider",
        actionID: "not-installed"
    )

    static func workflowAction(_ id: UUID) -> ActionReference {
        ActionReference(
            providerID: "automation",
            actionID: "workflow.\(id.uuidString.lowercased())"
        )
    }

    static func preserveSystemMute(_ isMuted: Bool) -> ActionReference {
        ActionReference(
            providerID: "system-mute",
            actionID: "set-enabled",
            booleanParameters: ["enabled": isMuted]
        )
    }

    static let openSettingsShortcut = ShortcutAssignment(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000250")!,
        reference: openSettings,
        binding: ShortcutBinding(keyCode: 20, modifiers: 3)
    )
    static let actionGridShortcut = ShortcutAssignment(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000251")!,
        reference: showActionGrid,
        binding: ShortcutBinding(keyCode: 21, modifiers: 3)
    )
    static let dashboardShortcut = ShortcutAssignment(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000264")!,
        reference: toggleDashboard,
        binding: ShortcutBinding(keyCode: 23, modifiers: 3)
    )
    static let workflowShortcut = ShortcutAssignment(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000265")!,
        reference: workflowAction(workflowID),
        binding: ShortcutBinding(keyCode: 22, modifiers: 3)
    )

    static let workflow = WorkflowDefinition(
        formatVersion: 1,
        id: workflowID,
        name: "E2E Safe Workflow",
        systemImage: "checkmark.seal",
        isEnabled: true,
        steps: [
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000252")!,
                reference: openSettings,
                label: "Open Settings",
                delaySeconds: 0.25,
                errorPolicy: "stop"
            ),
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000253")!,
                reference: toggleDashboard,
                label: "Show Dashboard",
                delaySeconds: 0.25,
                errorPolicy: "stop"
            ),
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000254")!,
                reference: openSettings,
                label: "Return to Settings",
                delaySeconds: 0,
                errorPolicy: "stop"
            ),
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static func automationWorkflow(systemMuted: Bool) -> WorkflowDefinition {
        WorkflowDefinition(
            formatVersion: 1,
            id: automationWorkflowID,
            name: "E2E Background Workflow",
            systemImage: "speaker.slash",
            isEnabled: true,
            steps: [
                WorkflowStep(
                    id: UUID(uuidString: "00000000-0000-4000-8000-000000000257")!,
                    reference: preserveSystemMute(systemMuted),
                    label: "Preserve System Mute",
                    delaySeconds: 0,
                    errorPolicy: "stop"
                ),
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    static let continueWorkflow = WorkflowDefinition(
        formatVersion: 1,
        id: continueWorkflowID,
        name: "E2E Continue After Missing Action",
        systemImage: "arrow.right.circle",
        isEnabled: true,
        steps: [
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000270")!,
                reference: openSettings,
                label: "Open Settings Before Failure",
                delaySeconds: 0,
                errorPolicy: "stop"
            ),
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000271")!,
                reference: missingAction,
                label: "Unavailable Provider Continues",
                delaySeconds: 0,
                errorPolicy: "continueRunning"
            ),
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000272")!,
                reference: openSettings,
                label: "Open Settings After Failure",
                delaySeconds: 0,
                errorPolicy: "stop"
            ),
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let stopWorkflow = WorkflowDefinition(
        formatVersion: 1,
        id: stopWorkflowID,
        name: "E2E Stop On Missing Action",
        systemImage: "stop.circle",
        isEnabled: true,
        steps: [
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000273")!,
                reference: missingAction,
                label: "Unavailable Provider Stops",
                delaySeconds: 0,
                errorPolicy: "stop"
            ),
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000274")!,
                reference: toggleDashboard,
                label: "Must Be Skipped",
                delaySeconds: 0,
                errorPolicy: "stop"
            ),
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let delayWorkflow = WorkflowDefinition(
        formatVersion: 1,
        id: delayWorkflowID,
        name: "E2E Cancellable Delay",
        systemImage: "timer",
        isEnabled: true,
        steps: [
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000275")!,
                reference: openSettings,
                label: "Cancel During Ten Second Delay",
                delaySeconds: 10,
                errorPolicy: "stop"
            ),
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let rule = AutomationRule(
        formatVersion: 1,
        id: ruleID,
        name: "E2E Calculator Activation",
        workflowID: automationWorkflowID,
        isEnabled: true,
        trigger: .application(
            ApplicationAutomationTrigger(
                event: .activates,
                bundleIdentifier: "com.apple.calculator"
            )
        ),
        conditions: [],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let calculatorSkipRule = AutomationRule(
        formatVersion: 1,
        id: calculatorSkipRuleID,
        name: "E2E Calculator Condition Skip",
        workflowID: automationWorkflowID,
        isEnabled: true,
        trigger: .application(
            ApplicationAutomationTrigger(
                event: .activates,
                bundleIdentifier: "com.apple.calculator"
            )
        ),
        conditions: [
            .frontmostApplication(
                FrontmostApplicationCondition(
                    bundleIdentifier: "com.example.never-frontmost",
                    isExcluded: false
                )
            ),
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let textEditRule = AutomationRule(
        formatVersion: 1,
        id: textEditRuleID,
        name: "E2E TextEdit Activation",
        workflowID: automationWorkflowID,
        isEnabled: true,
        trigger: .application(
            ApplicationAutomationTrigger(
                event: .activates,
                bundleIdentifier: "com.apple.TextEdit"
            )
        ),
        conditions: [],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let actionGridEntries = [
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000255")!,
            reference: openSettings,
            customTitle: "Settings"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000256")!,
            reference: toggleLaunchpad,
            customTitle: "Launchpad"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000300")!,
            reference: toggleDashboard,
            customTitle: "Dashboard"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000301")!,
            reference: toggleFeaturePanel,
            customTitle: "Feature Panel"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000302")!,
            reference: workflowAction(workflowID),
            customTitle: "Safe Workflow"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000303")!,
            reference: workflowAction(automationWorkflowID),
            customTitle: "Background Workflow"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000304")!,
            reference: workflowAction(continueWorkflowID),
            customTitle: "Continue Workflow"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000305")!,
            reference: workflowAction(stopWorkflowID),
            customTitle: "Stop Workflow"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000306")!,
            reference: missingAction,
            customTitle: "Unavailable Action"
        ),
    ]

}

private enum SystemAudioMuteState {
    static func currentSettableValue() -> Bool? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr,
            deviceID != kAudioObjectUnknown else {
            return nil
        }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else {
            return nil
        }

        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &mute
        ) == noErr else {
            return nil
        }
        return mute != 0
    }
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private let decoder = JSONDecoder()

private func encode<T: Encodable>(_ value: T) throws -> Data {
    do {
        return try encoder.encode(value)
    } catch {
        throw FixtureError.encoding("Could not encode E2E fixture: \(error)")
    }
}

private func loadShortcutPayload(from defaults: UserDefaults) -> ShortcutPayload {
    guard let data = defaults.data(forKey: Fixture.shortcutKey),
          let payload = try? decoder.decode(ShortcutPayload.self, from: data),
          payload.version == 1 else {
        return ShortcutPayload(version: 1, assignments: [])
    }
    return payload
}

private func seed(bundleIdentifier: String, allowRealDomain: Bool) throws {
    guard allowRealDomain || bundleIdentifier.contains(".e2e-test.") else {
        throw FixtureError.invalidArguments(
            "Seeding a real preferences domain requires --allow-real-domain."
        )
    }
    guard let defaults = UserDefaults(suiteName: bundleIdentifier) else {
        throw FixtureError.invalidArguments("Could not open preferences domain \(bundleIdentifier).")
    }
    guard let systemMuted = SystemAudioMuteState.currentSettableValue() else {
        throw FixtureError.invalidArguments(
            "The default audio output does not expose a settable mute state for the E2E fixture."
        )
    }

    var shortcuts = loadShortcutPayload(from: defaults).assignments
    let fixtureShortcuts = [
        Fixture.openSettingsShortcut,
        Fixture.actionGridShortcut,
        Fixture.dashboardShortcut,
        Fixture.workflowShortcut,
    ]
    let fixtureReferences = Set(fixtureShortcuts.map(\.reference))
    let fixtureBindings = Set(fixtureShortcuts.map(\.binding))
    shortcuts.removeAll {
        fixtureReferences.contains($0.reference) || fixtureBindings.contains($0.binding)
    }
    shortcuts.append(contentsOf: fixtureShortcuts)

    defaults.set(
        try encode(ShortcutPayload(version: 1, assignments: shortcuts)),
        forKey: Fixture.shortcutKey
    )
    defaults.set(
        try encode(WorkflowEnvelope(
            formatVersion: 1,
            workflows: [
                Fixture.workflow,
                Fixture.automationWorkflow(systemMuted: systemMuted),
                Fixture.continueWorkflow,
                Fixture.stopWorkflow,
                Fixture.delayWorkflow,
            ]
        )),
        forKey: Fixture.workflowKey
    )
    defaults.set(
        try encode(AutomationRuleEnvelope(
            formatVersion: 1,
            rules: [Fixture.rule, Fixture.calculatorSkipRule, Fixture.textEditRule]
        )),
        forKey: Fixture.ruleKey
    )
    defaults.set(
        try encode(ActionGridEnvelope(formatVersion: 1, entries: Fixture.actionGridEntries)),
        forKey: Fixture.actionGridKey
    )
    defaults.removeObject(forKey: Fixture.historyKey)
    defaults.set(Fixture.version, forKey: Fixture.markerKey)
    defaults.set("en", forKey: Fixture.languageKey)
    defaults.set(["en"], forKey: Fixture.appleLanguagesKey)
    defaults.set("light", forKey: Fixture.appearanceKey)
    guard defaults.synchronize() else {
        throw FixtureError.invalidArguments("Could not synchronize E2E preferences.")
    }
}

private func audit(bundleIdentifier: String) throws -> AuditReport {
    guard let defaults = UserDefaults(suiteName: bundleIdentifier) else {
        throw FixtureError.invalidArguments("Could not open preferences domain \(bundleIdentifier).")
    }
    let shortcuts = loadShortcutPayload(from: defaults).assignments
    let workflowEnvelope = defaults.data(forKey: Fixture.workflowKey)
        .flatMap { try? decoder.decode(WorkflowEnvelope.self, from: $0) }
    let ruleEnvelope = defaults.data(forKey: Fixture.ruleKey)
        .flatMap { try? decoder.decode(AutomationRuleEnvelope.self, from: $0) }
    let actionGridEnvelope = defaults.data(forKey: Fixture.actionGridKey)
        .flatMap { try? decoder.decode(ActionGridEnvelope.self, from: $0) }
    let workflows = workflowEnvelope?.workflows ?? []
    let rules = ruleEnvelope?.rules ?? []
    let actionGridEntries = actionGridEnvelope?.entries ?? []
    let historyRuns: [[String: Any]] = {
        guard let data = defaults.data(forKey: Fixture.historyKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = object["runs"] as? [[String: Any]] else {
            return []
        }
        return runs
    }()
    let latestHistory = historyRuns.first

    let hasOpenSettingsShortcut = shortcuts.contains {
        $0.reference == Fixture.openSettings && $0.binding == Fixture.openSettingsShortcut.binding
    }
    let hasActionGridShortcut = shortcuts.contains {
        $0.reference == Fixture.showActionGrid && $0.binding == Fixture.actionGridShortcut.binding
    }
    let hasDashboardShortcut = shortcuts.contains {
        $0.reference == Fixture.toggleDashboard && $0.binding == Fixture.dashboardShortcut.binding
    }
    let hasWorkflowShortcut = shortcuts.contains {
        $0.reference == Fixture.workflowAction(Fixture.workflowID)
            && $0.binding == Fixture.workflowShortcut.binding
    }
    let workflow = workflows.first { $0.id == Fixture.workflowID }
    let automationWorkflow = workflows.first { $0.id == Fixture.automationWorkflowID }
    let automationMuteSetting: Bool? = {
        guard let value = automationWorkflow?.steps.first?.reference.parameters.first?.value,
              case let .boolean(isMuted) = value else {
            return nil
        }
        return isMuted
    }()
    let automationWorkflowIsIdempotent = automationWorkflow?.steps.count == 1
        && automationWorkflow?.steps.first?.reference.key
            == ActionKey(providerID: "system-mute", actionID: "set-enabled")
        && automationWorkflow?.steps.first?.reference.parameters.count == 1
        && automationWorkflow?.steps.first?.reference.parameters.first?.name == "enabled"
        && {
            guard let value = automationWorkflow?.steps.first?.reference.parameters.first?.value,
                  case .boolean = value else {
                return false
            }
            return true
        }()
    let systemMuteStatePreserved = automationMuteSetting != nil
        && automationMuteSetting == SystemAudioMuteState.currentSettableValue()
    let calculatorRuleEnabled = rules.contains {
        guard $0.id == Fixture.ruleID,
              $0.workflowID == Fixture.automationWorkflowID,
              $0.isEnabled else {
            return false
        }
        guard case let .application(trigger) = $0.trigger else { return false }
        return trigger.bundleIdentifier == "com.apple.calculator" && trigger.event == .activates
    }
    let calculatorSkipRuleEnabled = rules.contains {
        guard $0.id == Fixture.calculatorSkipRuleID,
              $0.workflowID == Fixture.automationWorkflowID,
              $0.isEnabled else {
            return false
        }
        guard case let .application(trigger) = $0.trigger,
              trigger.bundleIdentifier == "com.apple.calculator",
              trigger.event == .activates,
              $0.conditions.count == 1,
              case let .frontmostApplication(condition) = $0.conditions[0] else {
            return false
        }
        return condition.bundleIdentifier == "com.example.never-frontmost"
            && !condition.isExcluded
    }
    let textEditRuleEnabled = rules.contains {
        guard $0.id == Fixture.textEditRuleID,
              $0.workflowID == Fixture.automationWorkflowID,
              $0.isEnabled,
              $0.conditions.isEmpty else {
            return false
        }
        guard case let .application(trigger) = $0.trigger else { return false }
        return trigger.bundleIdentifier == "com.apple.TextEdit" && trigger.event == .activates
    }
    let actionIDs = actionGridEntries.map { $0.reference.key.actionID }
    let actionGridReferences = actionGridEntries.map {
        "\($0.reference.key.providerID)/\($0.reference.key.actionID)"
    }
    let expectedWorkflowIDs: Set<UUID> = [
        Fixture.workflowID,
        Fixture.automationWorkflowID,
        Fixture.continueWorkflowID,
        Fixture.stopWorkflowID,
        Fixture.delayWorkflowID,
    ]
    let hasDisplaySleepWorkflowStep = workflows.contains { workflow in
        workflow.steps.contains {
            $0.reference.key == ActionKey(providerID: "display-sleep", actionID: "execute")
        }
    }
    let workflowsAreComplete = Set(workflows.map(\.id)) == expectedWorkflowIDs
        && workflows.first(where: { $0.id == Fixture.continueWorkflowID })?.steps.count == 3
        && workflows.first(where: { $0.id == Fixture.continueWorkflowID })?
            .steps.contains(where: {
                $0.reference == Fixture.missingAction && $0.errorPolicy == "continueRunning"
            }) == true
        && workflows.first(where: { $0.id == Fixture.stopWorkflowID })?.steps.count == 2
        && workflows.first(where: { $0.id == Fixture.stopWorkflowID })?
            .steps.first?.reference == Fixture.missingAction
        && workflows.first(where: { $0.id == Fixture.delayWorkflowID })?
            .steps.first?.delaySeconds == 10
    let language = defaults.string(forKey: Fixture.languageKey)
    let appearance = defaults.string(forKey: Fixture.appearanceKey)
    let expectedGridReferences = Fixture.actionGridEntries.map(\.reference)
    let hasUnavailableGridEntry = actionGridEntries.contains {
        $0.reference == Fixture.missingAction
    }
    let valid = defaults.integer(forKey: Fixture.markerKey) == Fixture.version
        && hasOpenSettingsShortcut
        && hasActionGridShortcut
        && hasDashboardShortcut
        && hasWorkflowShortcut
        && workflows.count == 5
        && workflowsAreComplete
        && !hasDisplaySleepWorkflowStep
        && workflow?.steps.count == 3
        && automationWorkflowIsIdempotent
        && systemMuteStatePreserved
        && calculatorRuleEnabled
        && calculatorSkipRuleEnabled
        && textEditRuleEnabled
        && rules.count == 3
        && actionGridEntries.map(\.reference) == expectedGridReferences
        && actionGridEntries.count == 9
        && hasUnavailableGridEntry
        && language == "en"
        && appearance == "light"

    return AuditReport(
        bundleIdentifier: bundleIdentifier,
        fixtureVersion: defaults.integer(forKey: Fixture.markerKey),
        valid: valid,
        shortcutCount: shortcuts.count,
        hasOpenSettingsShortcut: hasOpenSettingsShortcut,
        hasActionGridShortcut: hasActionGridShortcut,
        hasDashboardShortcut: hasDashboardShortcut,
        hasWorkflowShortcut: hasWorkflowShortcut,
        workflowCount: workflows.count,
        workflowNames: workflows.map(\.name),
        workflowStepCounts: Dictionary(
            uniqueKeysWithValues: workflows.map { ($0.name, $0.steps.count) }
        ),
        hasDisplaySleepWorkflowStep: hasDisplaySleepWorkflowStep,
        workflowName: workflow?.name,
        workflowStepCount: workflow?.steps.count ?? 0,
        automationWorkflowName: automationWorkflow?.name,
        automationWorkflowStepCount: automationWorkflow?.steps.count ?? 0,
        automationWorkflowIsIdempotent: automationWorkflowIsIdempotent,
        systemMuteValue: automationMuteSetting,
        systemMuteStatePreserved: systemMuteStatePreserved,
        ruleCount: rules.count,
        ruleNames: rules.map(\.name),
        calculatorRuleEnabled: calculatorRuleEnabled,
        calculatorSkipRuleEnabled: calculatorSkipRuleEnabled,
        textEditRuleEnabled: textEditRuleEnabled,
        actionGridEntryCount: actionGridEntries.count,
        actionGridActionIDs: actionIDs,
        actionGridReferences: actionGridReferences,
        hasUnavailableGridEntry: hasUnavailableGridEntry,
        language: language,
        appearance: appearance,
        workflowHistoryCount: historyRuns.count,
        latestWorkflowStatus: latestHistory?["status"] as? String,
        latestWorkflowSource: latestHistory?["source"].map { String(describing: $0) }
    )
}

private func clearTestDomain(_ bundleIdentifier: String) throws {
    guard bundleIdentifier.contains(".e2e-test.") else {
        throw FixtureError.unsafeDomain(bundleIdentifier)
    }
    UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
}

private func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first,
          let bundleIdentifier = argumentValue("--bundle-id", in: arguments),
          !bundleIdentifier.isEmpty else {
        throw FixtureError.invalidArguments(
            "Usage: MacToolsE2EFixture.swift <seed|audit|clear-test-domain> --bundle-id <id> [--allow-real-domain]"
        )
    }

    switch command {
    case "seed":
        try seed(
            bundleIdentifier: bundleIdentifier,
            allowRealDomain: arguments.contains("--allow-real-domain")
        )
        let report = try audit(bundleIdentifier: bundleIdentifier)
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard report.valid else { exit(2) }
    case "audit":
        let report = try audit(bundleIdentifier: bundleIdentifier)
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard report.valid else { exit(2) }
    case "clear-test-domain":
        try clearTestDomain(bundleIdentifier)
    default:
        throw FixtureError.invalidArguments("Unknown command: \(command)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
