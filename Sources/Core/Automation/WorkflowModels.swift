import Foundation
import MacToolsPluginKit

enum WorkflowStepErrorPolicy: String, Codable, CaseIterable, Sendable {
    case stop
    case continueRunning
}

struct WorkflowStep: Codable, Equatable, Sendable, Identifiable {
    static let maximumDelaySeconds: Double = 3_600
    static let maximumLabelByteCount = 120

    let id: UUID
    var reference: ActionReference
    var label: String?
    var delaySeconds: Double
    var errorPolicy: WorkflowStepErrorPolicy

    init(
        id: UUID = UUID(),
        reference: ActionReference,
        label: String? = nil,
        delaySeconds: Double = 0,
        errorPolicy: WorkflowStepErrorPolicy = .stop
    ) {
        self.id = id
        self.reference = reference
        self.label = label
        self.delaySeconds = delaySeconds
        self.errorPolicy = errorPolicy
    }
}

struct WorkflowDefinition: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1
    static let maximumNameByteCount = 80
    static let maximumStepCount = 64

    let formatVersion: Int
    let id: UUID
    var name: String
    var systemImage: String
    var isEnabled: Bool
    var steps: [WorkflowStep]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        systemImage: String = "bolt.horizontal.circle",
        isEnabled: Bool = true,
        steps: [WorkflowStep] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var actionKey: ActionKey {
        ActionKey(
            providerID: AutomationController.providerID,
            actionID: "workflow.\(id.uuidString.lowercased())"
        )
    }

    var actionReference: ActionReference {
        ActionReference(key: actionKey)
    }
}

enum WorkflowRunSource: Codable, Equatable, Sendable {
    case manual
    case test
    case publishedAction(ActionExecutionSource)
    case automatic(ruleID: UUID, triggerKind: String)
}

enum WorkflowRunStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
    case skipped
}

enum WorkflowStepRunStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case timedOut
    case unavailable
    case skipped
}

struct WorkflowStepRunResult: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let stepID: UUID
    let actionKey: ActionKey
    let title: String
    let startedAt: Date?
    let finishedAt: Date
    let status: WorkflowStepRunStatus
    let message: String?

    init(
        id: UUID = UUID(),
        stepID: UUID,
        actionKey: ActionKey,
        title: String,
        startedAt: Date?,
        finishedAt: Date,
        status: WorkflowStepRunStatus,
        message: String? = nil
    ) {
        self.id = id
        self.stepID = stepID
        self.actionKey = actionKey
        self.title = title
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.message = message
    }
}

struct WorkflowRun: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let id: UUID
    let workflowID: UUID
    let workflowName: String
    let source: WorkflowRunSource
    let startedAt: Date
    var finishedAt: Date?
    var status: WorkflowRunStatus
    var stepResults: [WorkflowStepRunResult]
    var summary: String?

    init(
        id: UUID = UUID(),
        workflowID: UUID,
        workflowName: String,
        source: WorkflowRunSource,
        startedAt: Date = .now,
        finishedAt: Date? = nil,
        status: WorkflowRunStatus = .running,
        stepResults: [WorkflowStepRunResult] = [],
        summary: String? = nil,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.source = source
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.stepResults = stepResults
        self.summary = summary
    }
}

enum WorkflowStoreError: Error, Equatable {
    case invalidWorkflow(String)
    case workflowNotFound
    case maximumWorkflowCountReached
    case persistenceFailed
    case unsafeForExport
    case invalidImport
}

enum WorkflowStartError: Error, Equatable {
    case workflowNotFound
    case workflowDisabled
    case emptyWorkflow
    case recursiveInvocation
    case maximumDepthExceeded
}

struct WorkflowExecutionHandle {
    let runID: UUID
    let actionHandle: ActionExecutionHandle
}

enum WorkflowExecutionContext {
    @TaskLocal static var workflowStack: [UUID] = []
}
