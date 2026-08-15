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

private struct SavedScriptFixture: Codable {
    let id: UUID
    let name: String
    let kind: String
    let source: String
    let workingDirectory: String
    let timeoutSeconds: Int
    let confirmOutsideManager: Bool
    let allowExternalInvocation: Bool
    let includeSourceInBackup: Bool
    let createdAt: Date
    let updatedAt: Date
}

private struct SavedScriptEnvelope: Codable {
    let formatVersion: Int
    let scripts: [SavedScriptFixture]
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

private struct ActionGridFolder: Codable {
    let systemImage: String
    let entries: [ActionGridEntry]
}

private struct ActionGridEntry: Codable {
    let id: UUID
    let reference: ActionReference
    let customTitle: String?
    let folder: ActionGridFolder?

    init(
        id: UUID,
        reference: ActionReference,
        customTitle: String?,
        folder: ActionGridFolder? = nil
    ) {
        self.id = id
        self.reference = reference
        self.customTitle = customTitle
        self.folder = folder
    }
}

private struct ActionGridEnvelope: Codable {
    let formatVersion: Int
    let entries: [ActionGridEntry]
}

private enum TrackpadGesture: String, Codable {
    case fourFingerLongTouch
    case fiveFingerLongTouch
}

private enum TrackpadGestureAction: Codable {
    case action(ActionReference)

    private enum CodingKeys: String, CodingKey {
        case kind
        case reference
    }

    private enum Kind: String, Codable {
        case action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(Kind.self, forKey: .kind)
        self = .action(try container.decode(ActionReference.self, forKey: .reference))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Kind.action, forKey: .kind)
        switch self {
        case let .action(reference):
            try container.encode(reference, forKey: .reference)
        }
    }
}

private struct TrackpadGestureMapping: Codable {
    let id: UUID
    let gesture: TrackpadGesture
    let action: TrackpadGestureAction
    let isEnabled: Bool
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
    let visualWorkflowName: String?
    let visualWorkflowStepCount: Int
    let visualWorkflowUsesSavedScript: Bool
    let visualWorkflowShowsActionGrid: Bool
    let automationWorkflowName: String?
    let automationWorkflowStepCount: Int
    let automationWorkflowIsIdempotent: Bool
    let runLinkWorkflowName: String?
    let runLinkWorkflowStepCount: Int
    let runLinkWorkflowIsIdempotent: Bool
    let systemMuteValue: Bool?
    let systemMuteStatePreserved: Bool
    let ruleCount: Int
    let ruleNames: [String]
    let primaryHelperRuleEnabled: Bool
    let primaryHelperSkipRuleEnabled: Bool
    let secondaryHelperRuleEnabled: Bool
    let savedScriptCount: Int
    let savedScriptName: String?
    let savedScriptActionID: String?
    let savedScriptRunsLocallyWithoutConfirmation: Bool
    let savedScriptRequiresExternalConfirmation: Bool
    let savedScriptIncludedInPortableBackup: Bool
    let savedScriptIncludedInActionGrid: Bool
    let savedScriptIncludedInVisualWorkflow: Bool
    let actionGridEntryCount: Int
    let actionGridTotalEntryCount: Int
    let actionGridFolderCount: Int
    let actionGridMaximumFolderDepth: Int
    let actionGridActionIDs: [String]
    let actionGridReferences: [String]
    let hasUnavailableGridEntry: Bool
    let trackpadMappingCount: Int
    let trackpadActionReferences: [String]
    let hasTrackpadActionGridMapping: Bool
    let hasTrackpadWorkflowMapping: Bool
    let language: String?
    let appearance: String?
    let workflowHistoryCount: Int
    let workflowHistoryIDs: [String]
    let workflowHistoryNames: [String]
    let workflowHistoryStatuses: [String]
    let latestWorkflowID: String?
    let latestWorkflowName: String?
    let latestWorkflowStatus: String?
    let latestWorkflowStepStatuses: [String]
    let latestWorkflowSource: String?
}

private enum Fixture {
    static let version = 7
    static let markerKey = "mactools.e2e.fixture-version"
    static let shortcutKey = "action-shortcuts.assignments"
    static let workflowKey = "automation.workflows.v1"
    static let ruleKey = "automation.rules.v1"
    static let historyKey = "automation.history.v1"
    static let savedScriptsKey = "plugin.saved-scripts.library.v1"
    static let actionGridKey = "plugin.action-grid.layout.v1"
    static let trackpadGestureKey = "plugin.trackpad-gestures.mappings"
    static let languageKey = "app.languagePreference"
    static let appleLanguagesKey = "AppleLanguages"
    static let appearanceKey = "app.appearancePreference"

    static let workflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000247")!
    static let automationWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000248")!
    static let continueWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000260")!
    static let stopWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000261")!
    static let delayWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000262")!
    static let visualWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000263")!
    static let runLinkWorkflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000266")!
    static let savedScriptID = UUID(uuidString: "00000000-0000-4000-8000-000000000290")!
    static let ruleID = UUID(uuidString: "00000000-0000-4000-8000-000000000249")!
    static let calculatorSkipRuleID = UUID(uuidString: "00000000-0000-4000-8000-000000000280")!
    static let textEditRuleID = UUID(uuidString: "00000000-0000-4000-8000-000000000281")!
    static let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let primaryPrivacyHelperBundleID = "com.jennymedia.mactools.e2e-helper.primary"
    static let secondaryPrivacyHelperBundleID = "com.jennymedia.mactools.e2e-helper.secondary"

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

    static let savedScriptAction = ActionReference(
        providerID: "saved-scripts",
        actionID: "run.\(savedScriptID.uuidString.lowercased())"
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

    static func runLinkWorkflow(systemMuted: Bool) -> WorkflowDefinition {
        WorkflowDefinition(
            formatVersion: 1,
            id: runLinkWorkflowID,
            name: "E2E Run Link Workflow",
            systemImage: "link",
            isEnabled: true,
            steps: [
                WorkflowStep(
                    id: UUID(uuidString: "00000000-0000-4000-8000-000000000267")!,
                    reference: preserveSystemMute(systemMuted),
                    label: "Preserve System Mute From Run Link",
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

    static let savedScript = SavedScriptFixture(
        id: savedScriptID,
        name: "E2E Privacy-Safe Visual Proof",
        kind: "zsh",
        source: """
        printf 'Opening the privacy-safe MacTools E2E helper.\\n'
        /usr/bin/open -b com.jennymedia.mactools.e2e-helper.primary
        /bin/sleep 3
        /usr/bin/open -a "$HOME/Applications/MacTools Dev.app" 'mactools-dev://app/settings/features/automation'
        /bin/sleep 1
        printf 'Returned to MacTools Automation.\\n'
        """,
        workingDirectory: "",
        timeoutSeconds: 15,
        confirmOutsideManager: false,
        allowExternalInvocation: true,
        includeSourceInBackup: true,
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let visualWorkflow = WorkflowDefinition(
        formatVersion: 1,
        id: visualWorkflowID,
        name: "E2E Visual Proof Workflow",
        systemImage: "sparkles.rectangle.stack",
        isEnabled: true,
        steps: [
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000276")!,
                reference: savedScriptAction,
                label: "Show Privacy-Safe Helper",
                delaySeconds: 0,
                errorPolicy: "stop"
            ),
            WorkflowStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000277")!,
                reference: showActionGrid,
                label: "Show Deterministic Action Grid",
                delaySeconds: 0.75,
                errorPolicy: "stop"
            ),
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let rule = AutomationRule(
        formatVersion: 1,
        id: ruleID,
        name: "E2E Privacy Helper Activation",
        workflowID: automationWorkflowID,
        isEnabled: true,
        trigger: .application(
            ApplicationAutomationTrigger(
                event: .activates,
                bundleIdentifier: primaryPrivacyHelperBundleID
            )
        ),
        conditions: [],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static let calculatorSkipRule = AutomationRule(
        formatVersion: 1,
        id: calculatorSkipRuleID,
        name: "E2E Privacy Helper Condition Skip",
        workflowID: automationWorkflowID,
        isEnabled: true,
        trigger: .application(
            ApplicationAutomationTrigger(
                event: .activates,
                bundleIdentifier: primaryPrivacyHelperBundleID
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
        name: "E2E Secondary Helper Activation",
        workflowID: automationWorkflowID,
        isEnabled: true,
        trigger: .application(
            ApplicationAutomationTrigger(
                event: .activates,
                bundleIdentifier: secondaryPrivacyHelperBundleID
            )
        ),
        conditions: [],
        createdAt: timestamp,
        updatedAt: timestamp
    )

    static func folderEntry(
        id: UUID,
        title: String,
        children: [ActionGridEntry]
    ) -> ActionGridEntry {
        ActionGridEntry(
            id: id,
            reference: ActionReference(
                providerID: "action-grid.folder",
                actionID: id.uuidString.lowercased()
            ),
            customTitle: title,
            folder: ActionGridFolder(systemImage: "folder.fill", entries: children)
        )
    }

    static let systemFolder = folderEntry(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000310")!,
        title: "System",
        children: [
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000311")!,
                reference: toggleDashboard,
                customTitle: nil
            ),
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000312")!,
                reference: toggleFeaturePanel,
                customTitle: nil
            ),
        ]
    )

    static let resilienceFolder = folderEntry(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000320")!,
        title: "Resilience",
        children: [
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000321")!,
                reference: workflowAction(continueWorkflowID),
                customTitle: "Continue"
            ),
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000322")!,
                reference: workflowAction(stopWorkflowID),
                customTitle: "Stop"
            ),
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000323")!,
                reference: workflowAction(delayWorkflowID),
                customTitle: "Cancellable Delay"
            ),
        ]
    )

    static let automationFolder = folderEntry(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000330")!,
        title: "Automation",
        children: [
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000331")!,
                reference: workflowAction(workflowID),
                customTitle: "Safe Workflow"
            ),
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000332")!,
                reference: workflowAction(automationWorkflowID),
                customTitle: "Background Workflow"
            ),
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000333")!,
                reference: workflowAction(visualWorkflowID),
                customTitle: "Visual Proof Workflow"
            ),
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000334")!,
                reference: savedScriptAction,
                customTitle: "Privacy-Safe Script"
            ),
            resilienceFolder,
        ]
    )

    static let utilitiesFolder = folderEntry(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000340")!,
        title: "Utilities",
        children: [
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000341")!,
                reference: openSettings,
                customTitle: nil
            ),
            ActionGridEntry(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000342")!,
                reference: toggleLaunchpad,
                customTitle: nil
            ),
        ]
    )

    static let actionGridEntries = [
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000255")!,
            reference: openSettings,
            customTitle: nil
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000256")!,
            reference: toggleLaunchpad,
            customTitle: nil
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000300")!,
            reference: toggleDashboard,
            customTitle: nil
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000301")!,
            reference: toggleFeaturePanel,
            customTitle: nil
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000302")!,
            reference: workflowAction(workflowID),
            customTitle: "Safe Workflow"
        ),
        ActionGridEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000306")!,
            reference: missingAction,
            customTitle: "Unavailable Action"
        ),
        systemFolder,
        automationFolder,
        utilitiesFolder,
    ]

    static let trackpadGestureMappings = [
        TrackpadGestureMapping(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000350")!,
            gesture: .fourFingerLongTouch,
            action: .action(showActionGrid),
            isEnabled: true
        ),
        TrackpadGestureMapping(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000351")!,
            gesture: .fiveFingerLongTouch,
            action: .action(workflowAction(workflowID)),
            isEnabled: true
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
    let systemMuted: Bool
    if let currentSystemMute = SystemAudioMuteState.currentSettableValue() {
        systemMuted = currentSystemMute
    } else if !allowRealDomain {
        // Script validation must remain deterministic on Macs whose selected
        // output device has no writable mute property.
        systemMuted = false
    } else {
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
                Fixture.visualWorkflow,
                Fixture.runLinkWorkflow(systemMuted: systemMuted),
            ]
        )),
        forKey: Fixture.workflowKey
    )
    defaults.set(
        try encode(SavedScriptEnvelope(formatVersion: 1, scripts: [Fixture.savedScript])),
        forKey: Fixture.savedScriptsKey
    )
    defaults.set(
        try encode(AutomationRuleEnvelope(
            formatVersion: 1,
            rules: [Fixture.rule, Fixture.calculatorSkipRule, Fixture.textEditRule]
        )),
        forKey: Fixture.ruleKey
    )
    defaults.set(
        try encode(ActionGridEnvelope(formatVersion: 2, entries: Fixture.actionGridEntries)),
        forKey: Fixture.actionGridKey
    )
    defaults.set(
        try encode(Fixture.trackpadGestureMappings),
        forKey: Fixture.trackpadGestureKey
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
    let savedScriptEnvelope = defaults.data(forKey: Fixture.savedScriptsKey)
        .flatMap { try? decoder.decode(SavedScriptEnvelope.self, from: $0) }
    let ruleEnvelope = defaults.data(forKey: Fixture.ruleKey)
        .flatMap { try? decoder.decode(AutomationRuleEnvelope.self, from: $0) }
    let actionGridEnvelope = defaults.data(forKey: Fixture.actionGridKey)
        .flatMap { try? decoder.decode(ActionGridEnvelope.self, from: $0) }
    let trackpadMappings = defaults.data(forKey: Fixture.trackpadGestureKey)
        .flatMap { try? decoder.decode([TrackpadGestureMapping].self, from: $0) }
        ?? []
    let workflows = workflowEnvelope?.workflows ?? []
    let savedScripts = savedScriptEnvelope?.scripts ?? []
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
    let latestWorkflowSteps = latestHistory?["stepResults"] as? [[String: Any]] ?? []

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
    let visualWorkflow = workflows.first { $0.id == Fixture.visualWorkflowID }
    let visualWorkflowUsesSavedScript = visualWorkflow?.steps.first?.reference
        == Fixture.savedScriptAction
    let visualWorkflowShowsActionGrid = visualWorkflow?.steps.last?.reference
        == Fixture.showActionGrid
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
    let runLinkWorkflow = workflows.first { $0.id == Fixture.runLinkWorkflowID }
    let runLinkMuteSetting: Bool? = {
        guard let value = runLinkWorkflow?.steps.first?.reference.parameters.first?.value,
              case let .boolean(isMuted) = value else {
            return nil
        }
        return isMuted
    }()
    let runLinkWorkflowIsIdempotent = runLinkWorkflow?.steps.count == 1
        && runLinkWorkflow?.steps.first?.reference.key
            == ActionKey(providerID: "system-mute", actionID: "set-enabled")
        && runLinkWorkflow?.steps.first?.reference.parameters.count == 1
        && runLinkWorkflow?.steps.first?.reference.parameters.first?.name == "enabled"
        && runLinkMuteSetting == automationMuteSetting
    let currentSystemMute = SystemAudioMuteState.currentSettableValue()
    let permitsUnavailableTestAudio = bundleIdentifier.contains(".e2e-test.")
        && currentSystemMute == nil
    let systemMuteStatePreserved = automationMuteSetting != nil
        && (automationMuteSetting == currentSystemMute || permitsUnavailableTestAudio)
        && runLinkMuteSetting == automationMuteSetting
    let primaryHelperRuleEnabled = rules.contains {
        guard $0.id == Fixture.ruleID,
              $0.workflowID == Fixture.automationWorkflowID,
              $0.isEnabled else {
            return false
        }
        guard case let .application(trigger) = $0.trigger else { return false }
        return trigger.bundleIdentifier == Fixture.primaryPrivacyHelperBundleID
            && trigger.event == .activates
    }
    let primaryHelperSkipRuleEnabled = rules.contains {
        guard $0.id == Fixture.calculatorSkipRuleID,
              $0.workflowID == Fixture.automationWorkflowID,
              $0.isEnabled else {
            return false
        }
        guard case let .application(trigger) = $0.trigger,
              trigger.bundleIdentifier == Fixture.primaryPrivacyHelperBundleID,
              trigger.event == .activates,
              $0.conditions.count == 1,
              case let .frontmostApplication(condition) = $0.conditions[0] else {
            return false
        }
        return condition.bundleIdentifier == "com.example.never-frontmost"
            && !condition.isExcluded
    }
    let secondaryHelperRuleEnabled = rules.contains {
        guard $0.id == Fixture.textEditRuleID,
              $0.workflowID == Fixture.automationWorkflowID,
              $0.isEnabled,
              $0.conditions.isEmpty else {
            return false
        }
        guard case let .application(trigger) = $0.trigger else { return false }
        return trigger.bundleIdentifier == Fixture.secondaryPrivacyHelperBundleID
            && trigger.event == .activates
    }
    let savedScript = savedScripts.first { $0.id == Fixture.savedScriptID }
    let savedScriptRunsLocallyWithoutConfirmation = savedScript?.confirmOutsideManager == false
    let savedScriptRequiresExternalConfirmation = savedScript?.allowExternalInvocation == true
    let savedScriptIncludedInPortableBackup = savedScript?.includeSourceInBackup == true
    func flattenedGridEntries(
        _ entries: [ActionGridEntry],
        depth: Int = 0
    ) -> [(entry: ActionGridEntry, depth: Int)] {
        entries.flatMap { entry in
            [(entry, depth)] + flattenedGridEntries(entry.folder?.entries ?? [], depth: depth + 1)
        }
    }
    let flattenedGrid = flattenedGridEntries(actionGridEntries)
    let actionEntries = flattenedGrid.map(\.entry).filter { $0.folder == nil }
    let actionIDs = actionEntries.map { $0.reference.key.actionID }
    let actionGridReferences = actionEntries.map {
        "\($0.reference.key.providerID)/\($0.reference.key.actionID)"
    }
    let trackpadActionReferences = trackpadMappings.compactMap { mapping -> String? in
        guard case let .action(reference) = mapping.action else { return nil }
        return "\(reference.key.providerID)/\(reference.key.actionID)"
    }
    let expectedWorkflowIDs: Set<UUID> = [
        Fixture.workflowID,
        Fixture.automationWorkflowID,
        Fixture.continueWorkflowID,
        Fixture.stopWorkflowID,
        Fixture.delayWorkflowID,
        Fixture.visualWorkflowID,
        Fixture.runLinkWorkflowID,
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
        && runLinkWorkflowIsIdempotent
        && visualWorkflow?.steps.count == 2
        && visualWorkflowUsesSavedScript
        && visualWorkflowShowsActionGrid
    let language = defaults.string(forKey: Fixture.languageKey)
    let appearance = defaults.string(forKey: Fixture.appearanceKey)
    let expectedGridReferences = Fixture.actionGridEntries.map(\.reference)
    let hasUnavailableGridEntry = actionEntries.contains {
        $0.reference == Fixture.missingAction
    }
    let savedScriptIncludedInActionGrid = actionEntries.contains {
        $0.reference == Fixture.savedScriptAction
    }
    let savedScriptIncludedInVisualWorkflow = visualWorkflow?.steps.contains {
        $0.reference == Fixture.savedScriptAction
    } == true
    let hasTrackpadActionGridMapping = trackpadMappings.contains { mapping in
        guard mapping.gesture == .fourFingerLongTouch,
              mapping.isEnabled,
              case let .action(reference) = mapping.action else {
            return false
        }
        return reference == Fixture.showActionGrid
    }
    let hasTrackpadWorkflowMapping = trackpadMappings.contains { mapping in
        guard mapping.gesture == .fiveFingerLongTouch,
              mapping.isEnabled,
              case let .action(reference) = mapping.action else {
            return false
        }
        return reference == Fixture.workflowAction(Fixture.workflowID)
    }
    let valid = defaults.integer(forKey: Fixture.markerKey) == Fixture.version
        && hasOpenSettingsShortcut
        && hasActionGridShortcut
        && hasDashboardShortcut
        && hasWorkflowShortcut
        && workflows.count == 7
        && workflowsAreComplete
        && !hasDisplaySleepWorkflowStep
        && workflow?.steps.count == 3
        && automationWorkflowIsIdempotent
        && systemMuteStatePreserved
        && primaryHelperRuleEnabled
        && primaryHelperSkipRuleEnabled
        && secondaryHelperRuleEnabled
        && rules.count == 3
        && savedScripts.count == 1
        && savedScript?.name == Fixture.savedScript.name
        && savedScript?.source == Fixture.savedScript.source
        && savedScriptRunsLocallyWithoutConfirmation
        && savedScriptRequiresExternalConfirmation
        && savedScriptIncludedInPortableBackup
        && savedScriptIncludedInActionGrid
        && savedScriptIncludedInVisualWorkflow
        && actionGridEntries.map(\.reference) == expectedGridReferences
        && actionGridEntries.count == 9
        && flattenedGrid.count == 21
        && flattenedGrid.filter({ $0.entry.folder != nil }).count == 4
        && flattenedGrid.map(\.depth).max() == 2
        && hasUnavailableGridEntry
        && trackpadMappings.count == 2
        && hasTrackpadActionGridMapping
        && hasTrackpadWorkflowMapping
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
        visualWorkflowName: visualWorkflow?.name,
        visualWorkflowStepCount: visualWorkflow?.steps.count ?? 0,
        visualWorkflowUsesSavedScript: visualWorkflowUsesSavedScript,
        visualWorkflowShowsActionGrid: visualWorkflowShowsActionGrid,
        automationWorkflowName: automationWorkflow?.name,
        automationWorkflowStepCount: automationWorkflow?.steps.count ?? 0,
        automationWorkflowIsIdempotent: automationWorkflowIsIdempotent,
        runLinkWorkflowName: runLinkWorkflow?.name,
        runLinkWorkflowStepCount: runLinkWorkflow?.steps.count ?? 0,
        runLinkWorkflowIsIdempotent: runLinkWorkflowIsIdempotent,
        systemMuteValue: automationMuteSetting,
        systemMuteStatePreserved: systemMuteStatePreserved,
        ruleCount: rules.count,
        ruleNames: rules.map(\.name),
        primaryHelperRuleEnabled: primaryHelperRuleEnabled,
        primaryHelperSkipRuleEnabled: primaryHelperSkipRuleEnabled,
        secondaryHelperRuleEnabled: secondaryHelperRuleEnabled,
        savedScriptCount: savedScripts.count,
        savedScriptName: savedScript?.name,
        savedScriptActionID: savedScript.map { "run.\($0.id.uuidString.lowercased())" },
        savedScriptRunsLocallyWithoutConfirmation: savedScriptRunsLocallyWithoutConfirmation,
        savedScriptRequiresExternalConfirmation: savedScriptRequiresExternalConfirmation,
        savedScriptIncludedInPortableBackup: savedScriptIncludedInPortableBackup,
        savedScriptIncludedInActionGrid: savedScriptIncludedInActionGrid,
        savedScriptIncludedInVisualWorkflow: savedScriptIncludedInVisualWorkflow,
        actionGridEntryCount: actionGridEntries.count,
        actionGridTotalEntryCount: flattenedGrid.count,
        actionGridFolderCount: flattenedGrid.filter { $0.entry.folder != nil }.count,
        actionGridMaximumFolderDepth: flattenedGrid.map(\.depth).max() ?? 0,
        actionGridActionIDs: actionIDs,
        actionGridReferences: actionGridReferences,
        hasUnavailableGridEntry: hasUnavailableGridEntry,
        trackpadMappingCount: trackpadMappings.count,
        trackpadActionReferences: trackpadActionReferences,
        hasTrackpadActionGridMapping: hasTrackpadActionGridMapping,
        hasTrackpadWorkflowMapping: hasTrackpadWorkflowMapping,
        language: language,
        appearance: appearance,
        workflowHistoryCount: historyRuns.count,
        workflowHistoryIDs: historyRuns.compactMap { $0["workflowID"] as? String },
        workflowHistoryNames: historyRuns.compactMap { $0["workflowName"] as? String },
        workflowHistoryStatuses: historyRuns.compactMap { $0["status"] as? String },
        latestWorkflowID: latestHistory?["workflowID"] as? String,
        latestWorkflowName: latestHistory?["workflowName"] as? String,
        latestWorkflowStatus: latestHistory?["status"] as? String,
        latestWorkflowStepStatuses: latestWorkflowSteps.compactMap { $0["status"] as? String },
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
