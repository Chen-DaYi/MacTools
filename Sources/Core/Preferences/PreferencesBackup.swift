import Foundation
import MacToolsPluginKit

struct PreferencesBackup: Codable, Equatable, Sendable {
    static let currentFormatVersion = 5
    static let maximumFileSize = 4 * 1024 * 1024

    struct ApplicationPreferences: Codable, Equatable, Sendable {
        let appearancePreference: String
        let languagePreference: String
        let menuBarClickBehavior: String
    }

    let formatVersion: Int
    let exportedAt: Date
    let application: ApplicationPreferences
    let pluginDisplay: PluginDisplayPreferencesBackup
    let shortcutCustomizations: [String: ShortcutCustomization]
    let actionShortcutAssignments: [ActionShortcutAssignmentRecord]
    let pluginPreferences: [String: Data]
    let actionInvocationPresets: [ActionInvocationPreset]?
    let workflows: [WorkflowDefinition]?
    let automationRules: [AutomationRule]?
    let selection: PreferencesBackupSelection?

    init(
        application: ApplicationPreferences,
        pluginDisplay: PluginDisplayPreferencesBackup,
        shortcutCustomizations: [String: ShortcutCustomization],
        actionShortcutAssignments: [ActionShortcutAssignmentRecord] = [],
        pluginPreferences: [String: Data] = [:],
        actionInvocationPresets: [ActionInvocationPreset]? = [],
        workflows: [WorkflowDefinition]? = [],
        automationRules: [AutomationRule]? = [],
        selection: PreferencesBackupSelection? = nil,
        exportedAt: Date = .now
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.application = application
        self.pluginDisplay = pluginDisplay
        self.shortcutCustomizations = shortcutCustomizations
        self.actionShortcutAssignments = actionShortcutAssignments
        self.pluginPreferences = pluginPreferences
        self.actionInvocationPresets = actionInvocationPresets
        self.workflows = workflows
        self.automationRules = automationRules
        self.selection = selection ?? .all(pluginPreferenceIDs: Set(pluginPreferences.keys))
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case application
        case pluginDisplay
        case shortcutCustomizations
        case actionShortcutAssignments
        case pluginPreferences
        case actionInvocationPresets
        case workflows
        case automationRules
        case selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        application = try container.decode(ApplicationPreferences.self, forKey: .application)
        pluginDisplay = try container.decode(PluginDisplayPreferencesBackup.self, forKey: .pluginDisplay)
        shortcutCustomizations = try container.decode(
            [String: ShortcutCustomization].self,
            forKey: .shortcutCustomizations
        )
        actionShortcutAssignments = try container.decodeIfPresent(
            [ActionShortcutAssignmentRecord].self,
            forKey: .actionShortcutAssignments
        ) ?? []
        pluginPreferences = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .pluginPreferences
        ) ?? [:]
        actionInvocationPresets = try container.decodeIfPresent(
            [ActionInvocationPreset].self,
            forKey: .actionInvocationPresets
        )
        workflows = try container.decodeIfPresent(
            [WorkflowDefinition].self,
            forKey: .workflows
        )
        automationRules = try container.decodeIfPresent(
            [AutomationRule].self,
            forKey: .automationRules
        )
        selection = try container.decodeIfPresent(
            PreferencesBackupSelection.self,
            forKey: .selection
        )
        if formatVersion >= 4,
           actionInvocationPresets == nil || workflows == nil || automationRules == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 4 backups must include Run Link presets, workflows, and automation rules."
                )
            )
        }
        if formatVersion >= 5, selection == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 5 backups must describe the selected preference categories."
                )
            )
        }
    }

    func validate() throws {
        guard (1 ... Self.currentFormatVersion).contains(formatVersion) else {
            throw PreferencesBackupError.unsupportedFormatVersion(formatVersion)
        }
    }

    func validateApplicationPreferences(
        using validator: (ApplicationPreferences) -> Bool
    ) throws {
        guard !effectiveSelection.includesApplicationPreferences || validator(application) else {
            throw PreferencesBackupError.invalidApplicationPreferences
        }
    }

    var effectiveSelection: PreferencesBackupSelection {
        selection ?? .all(pluginPreferenceIDs: Set(pluginPreferences.keys))
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeJSON(_ data: Data) throws -> PreferencesBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(PreferencesBackup.self, from: data)
        try backup.validate()
        return backup
    }

    static func decodeJSON(
        contentsOf url: URL,
        maximumFileSize: Int = maximumFileSize
    ) async throws -> PreferencesBackup {
        try await Task.detached(priority: .userInitiated) {
            let data = try Self.readFile(at: url, maximumSize: maximumFileSize)
            return try Self.decodeJSON(data)
        }.value
    }

    private static func readFile(at url: URL, maximumSize: Int) throws -> Data {
        precondition(maximumSize > 0)

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var data = Data()
        data.reserveCapacity(maximumSize + 1)

        while data.count <= maximumSize {
            let remainingByteCount = maximumSize + 1 - data.count
            guard let chunk = try file.read(upToCount: min(64 * 1024, remainingByteCount)),
                  !chunk.isEmpty
            else {
                break
            }

            data.append(chunk)
        }

        guard data.count <= maximumSize else {
            throw PreferencesBackupError.fileTooLarge(maximumBytes: maximumSize)
        }

        return data
    }
}

struct PreferencesBackupSelection: Codable, Equatable, Sendable {
    var includesApplicationPreferences: Bool
    var includesPluginLayout: Bool
    var includesShortcuts: Bool
    var includesAutomation: Bool
    var includesRunLinks: Bool
    var pluginPreferenceIDs: Set<String>

    static func all(pluginPreferenceIDs: Set<String>) -> Self {
        Self(
            includesApplicationPreferences: true,
            includesPluginLayout: true,
            includesShortcuts: true,
            includesAutomation: true,
            includesRunLinks: true,
            pluginPreferenceIDs: pluginPreferenceIDs
        )
    }

    var isEmpty: Bool {
        !includesApplicationPreferences
            && !includesPluginLayout
            && !includesShortcuts
            && !includesAutomation
            && !includesRunLinks
            && pluginPreferenceIDs.isEmpty
    }
}

struct PluginDisplayPreferencesBackup: Codable, Equatable, Sendable {
    let orderedPluginIDs: [String]
    /// Compatibility projection for app versions that only understood global
    /// visibility. New imports prefer the two per-surface collections below.
    let hiddenPluginIDs: [String]
    let dashboardOrderedPluginIDs: [String]?
    let featurePanelOrderedPluginIDs: [String]?
    let dashboardHiddenPluginIDs: [String]?
    let featurePanelHiddenPluginIDs: [String]?

    init(
        orderedPluginIDs: [String],
        hiddenPluginIDs: [String],
        dashboardOrderedPluginIDs: [String]? = nil,
        featurePanelOrderedPluginIDs: [String]? = nil,
        dashboardHiddenPluginIDs: [String]? = nil,
        featurePanelHiddenPluginIDs: [String]? = nil
    ) {
        self.orderedPluginIDs = orderedPluginIDs
        self.hiddenPluginIDs = hiddenPluginIDs
        self.dashboardOrderedPluginIDs = dashboardOrderedPluginIDs
        self.featurePanelOrderedPluginIDs = featurePanelOrderedPluginIDs
        self.dashboardHiddenPluginIDs = dashboardHiddenPluginIDs
        self.featurePanelHiddenPluginIDs = featurePanelHiddenPluginIDs
    }
}

struct PreferencesImportPreview: Equatable {
    let pluginCount: Int
    let unavailablePluginIDs: [String]
    let shortcutCount: Int
    let unavailableShortcutIDs: [String]
    let unavailableActionReferences: [ActionReference]
    let installablePlugins: [PreferencesImportInstallablePlugin]
    let selection: PreferencesBackupSelection

    static func make(
        backup: PreferencesBackup,
        availablePluginIDs: Set<String>,
        availableShortcutIDs: Set<String>,
        availableActionReferences: Set<ActionReference> = [],
        pluginManagementItems: [PluginManagementItem],
        selection requestedSelection: PreferencesBackupSelection? = nil,
        applicationPreferencesAreValid: (PreferencesBackup.ApplicationPreferences) -> Bool
    ) throws -> PreferencesImportPreview {
        try backup.validate()
        let selection = requestedSelection ?? backup.effectiveSelection
        if selection.includesApplicationPreferences,
           !applicationPreferencesAreValid(backup.application) {
            throw PreferencesBackupError.invalidApplicationPreferences
        }

        let displayPluginIDs: Set<String> = selection.includesPluginLayout
            ? Set(backup.pluginDisplay.orderedPluginIDs)
            .union(backup.pluginDisplay.hiddenPluginIDs)
            .union(backup.pluginDisplay.dashboardOrderedPluginIDs ?? [])
            .union(backup.pluginDisplay.featurePanelOrderedPluginIDs ?? [])
            .union(backup.pluginDisplay.dashboardHiddenPluginIDs ?? [])
            .union(backup.pluginDisplay.featurePanelHiddenPluginIDs ?? [])
            : []
        let shortcutPluginIDs: Set<String> = selection.includesShortcuts
            ? Set(
                backup.actionShortcutAssignments.compactMap {
                    $0.reference.key.providerID == "mactools"
                        ? nil
                        : $0.reference.key.providerID
                }
            )
            : []
        let backedUpPluginIDs = displayPluginIDs
            .union(selection.pluginPreferenceIDs.intersection(backup.pluginPreferences.keys))
            .union(shortcutPluginIDs)
        let missingPluginIDs = backedUpPluginIDs.subtracting(availablePluginIDs)
        let managementItemsByID = Dictionary(
            pluginManagementItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let installablePlugins = missingPluginIDs.compactMap { pluginID -> PreferencesImportInstallablePlugin? in
            guard let item = managementItemsByID[pluginID], item.canInstall else { return nil }
            return PreferencesImportInstallablePlugin(
                id: item.id,
                title: item.title,
                summary: item.summary,
                version: item.version
            )
        }
        let installablePluginIDs = Set(installablePlugins.map(\.id))
        let compatibilityShortcutIDs: Set<String> = selection.includesShortcuts ? Set(
            backup.actionShortcutAssignments.compactMap { assignment in
                assignment.reference.key.providerID == "mactools"
                    ? assignment.reference.key.actionID
                    : nil
            }
        ) : []
        let backedUpShortcutIDs: Set<String> = (selection.includesShortcuts
            ? Set(backup.shortcutCustomizations.keys)
            : [])
            .subtracting(compatibilityShortcutIDs)
        let availableActionCount = (selection.includesShortcuts ? backup.actionShortcutAssignments : []).filter {
            availableActionReferences.contains($0.reference)
        }.count
        let unavailableActionReferences = (selection.includesShortcuts ? backup.actionShortcutAssignments : [])
            .map(\.reference)
            .filter { !availableActionReferences.contains($0) }
        return PreferencesImportPreview(
            pluginCount: backedUpPluginIDs.intersection(availablePluginIDs).count,
            unavailablePluginIDs: missingPluginIDs.subtracting(installablePluginIDs).sorted(),
            shortcutCount: backedUpShortcutIDs.intersection(availableShortcutIDs).count
                + availableActionCount,
            unavailableShortcutIDs: backedUpShortcutIDs.subtracting(availableShortcutIDs).sorted(),
            unavailableActionReferences: unavailableActionReferences,
            installablePlugins: installablePlugins.sorted { $0.title.localizedCompare($1.title) == .orderedAscending },
            selection: selection
        )
    }
}

struct PreferencesImportInstallablePlugin: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String?
    let version: String
}

struct PreferencesImportResult: Equatable {
    let installedPluginIDs: [String]
    let pluginInstallationFailures: [String: String]
    let shortcutErrors: [String: String]
}

enum PreferencesBackupError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case invalidApplicationPreferences
    case fileTooLarge(maximumBytes: Int)
}

@MainActor
protocol PreferencesBackupApplicationStoring: AnyObject {
    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences
    func validates(_ preferences: PreferencesBackup.ApplicationPreferences) -> Bool
    func apply(_ preferences: PreferencesBackup.ApplicationPreferences)
}
