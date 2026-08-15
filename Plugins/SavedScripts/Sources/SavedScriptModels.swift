import Foundation

enum SavedScriptKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleScript
    case zsh
    case bash
    case sh

    var id: String { rawValue }

    var executableURL: URL {
        switch self {
        case .appleScript:
            URL(fileURLWithPath: "/usr/bin/osascript")
        case .zsh:
            URL(fileURLWithPath: "/bin/zsh")
        case .bash:
            URL(fileURLWithPath: "/bin/bash")
        case .sh:
            URL(fileURLWithPath: "/bin/sh")
        }
    }

    var fileExtension: String {
        switch self {
        case .appleScript: "applescript"
        case .zsh: "zsh"
        case .bash: "bash"
        case .sh: "sh"
        }
    }

    var systemImage: String {
        switch self {
        case .appleScript: "scroll"
        case .zsh, .bash, .sh: "terminal"
        }
    }

    var defaultSource: String {
        switch self {
        case .appleScript:
            "return \"Hello from MacTools\""
        case .zsh, .bash, .sh:
            "echo \"Hello from MacTools\""
        }
    }
}

struct SavedScript: Codable, Equatable, Identifiable, Sendable {
    static let maximumNameByteCount = 80
    static let maximumSourceByteCount = 64 * 1_024
    static let maximumWorkingDirectoryByteCount = 1_024
    static let minimumTimeoutSeconds = 1
    static let maximumTimeoutSeconds = 300

    let id: UUID
    var name: String
    var kind: SavedScriptKind
    var source: String
    var workingDirectory: String
    var timeoutSeconds: Int
    var confirmOutsideManager: Bool
    var allowExternalInvocation: Bool
    var includeSourceInBackup: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: SavedScriptKind,
        source: String,
        workingDirectory: String = "",
        timeoutSeconds: Int = 30,
        confirmOutsideManager: Bool = true,
        allowExternalInvocation: Bool = false,
        includeSourceInBackup: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.confirmOutsideManager = confirmOutsideManager
        self.allowExternalInvocation = allowExternalInvocation
        self.includeSourceInBackup = includeSourceInBackup
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func draft(kind: SavedScriptKind = .zsh) -> SavedScript {
        SavedScript(name: "", kind: kind, source: kind.defaultSource)
    }

    var actionID: String {
        "run.\(id.uuidString.lowercased())"
    }

    func normalized(now: Date = .now) throws -> SavedScript {
        var script = self
        script.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        script.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        script.updatedAt = now

        guard !script.name.isEmpty else {
            throw SavedScriptValidationError.emptyName
        }
        guard script.name.utf8.count <= Self.maximumNameByteCount else {
            throw SavedScriptValidationError.nameTooLong
        }
        guard !script.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SavedScriptValidationError.emptySource
        }
        guard script.source.utf8.count <= Self.maximumSourceByteCount else {
            throw SavedScriptValidationError.sourceTooLong
        }
        guard script.workingDirectory.utf8.count <= Self.maximumWorkingDirectoryByteCount else {
            throw SavedScriptValidationError.workingDirectoryTooLong
        }
        guard (Self.minimumTimeoutSeconds ... Self.maximumTimeoutSeconds)
            .contains(script.timeoutSeconds) else {
            throw SavedScriptValidationError.invalidTimeout
        }
        return script
    }

    func portableCopy() -> SavedScript {
        var copy = self
        copy.workingDirectory = ""
        return copy
    }

    func hardenedAfterPortableRestore() -> SavedScript {
        var copy = portableCopy()
        copy.confirmOutsideManager = true
        copy.allowExternalInvocation = false
        return copy
    }
}

enum SavedScriptValidationError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong
    case emptySource
    case sourceTooLong
    case workingDirectoryTooLong
    case invalidTimeout
    case tooManyScripts
    case payloadTooLarge
    case duplicateID
    case persistenceFailed
    case recoveryRequired

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a script name."
        case .nameTooLong: "The script name is too long."
        case .emptySource: "Enter script source."
        case .sourceTooLong: "The script source is too large."
        case .workingDirectoryTooLong: "The working directory path is too long."
        case .invalidTimeout: "Choose a timeout between 1 and 300 seconds."
        case .tooManyScripts: "Saved Scripts supports up to 32 scripts."
        case .payloadTooLarge: "The saved script library is too large."
        case .duplicateID: "The script identifier is already in use."
        case .persistenceFailed: "The saved script library could not be saved."
        case .recoveryRequired: "Recover or reset the unreadable script library before editing it."
        }
    }
}

enum SavedScriptRunStatus: Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

struct SavedScriptRunRecord: Equatable, Identifiable, Sendable {
    let id: UUID
    let scriptID: UUID
    let scriptName: String
    let startedAt: Date
    var finishedAt: Date?
    var status: SavedScriptRunStatus
    var exitCode: Int32?
    var standardOutput: String
    var standardError: String
    var message: String?
    var outputWasTruncated: Bool
}
