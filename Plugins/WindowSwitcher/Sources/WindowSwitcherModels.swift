import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MacToolsPluginKit

enum WindowSwitcherConstants {
    static let pluginID = "window-switcher"
    static let shortcutDefinitionID = "switcher"
    static let shortcutActionID = "switch"
    static let accessibilityPermissionID = "accessibility"
}

enum WindowSwitcherMode: String, Codable, CaseIterable, Identifiable {
    case keyWindow
    case directCycle

    var id: String { rawValue }
}

enum WindowSwitcherSortMode: String, Codable, CaseIterable, Identifiable {
    case recentUse
    case fixed

    var id: String { rawValue }
}

struct WindowSwitcherConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var mode: WindowSwitcherMode
    var sortMode: WindowSwitcherSortMode

    init(
        isEnabled: Bool,
        mode: WindowSwitcherMode,
        sortMode: WindowSwitcherSortMode
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.sortMode = sortMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.mode = try container.decodeIfPresent(WindowSwitcherMode.self, forKey: .mode) ?? .keyWindow
        self.sortMode = try container.decodeIfPresent(WindowSwitcherSortMode.self, forKey: .sortMode) ?? .recentUse
    }

    static let `default` = WindowSwitcherConfiguration(
        isEnabled: true,
        mode: .keyWindow,
        sortMode: .recentUse
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case mode
        case sortMode
    }
}

@MainActor
final class WindowSwitcherStore: ObservableObject {
    private enum Keys {
        static let configuration = "configuration"
        static let shortcutAssignments = "shortcut-assignments"
    }

    @Published private(set) var configuration: WindowSwitcherConfiguration
    @Published private(set) var shortcutAssignments: [String: String]

    private let storage: PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: PluginStorage) {
        self.storage = storage
        if let data = storage.data(forKey: Keys.configuration),
           let loaded = try? decoder.decode(WindowSwitcherConfiguration.self, from: data) {
            self.configuration = loaded
        } else {
            self.configuration = .default
        }

        if let data = storage.data(forKey: Keys.shortcutAssignments),
           let loaded = try? decoder.decode([String: String].self, from: data) {
            self.shortcutAssignments = loaded
        } else {
            self.shortcutAssignments = [:]
        }
    }

    func setMode(_ mode: WindowSwitcherMode) {
        guard configuration.mode != mode else {
            return
        }

        configuration.mode = mode
        persist()
    }

    func setSortMode(_ sortMode: WindowSwitcherSortMode) {
        guard configuration.sortMode != sortMode else {
            return
        }

        configuration.sortMode = sortMode
        persist()
    }

    func setEnabled(_ isEnabled: Bool) {
        guard configuration.isEnabled != isEnabled else {
            return
        }

        configuration.isEnabled = isEnabled
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(configuration) else {
            return
        }

        storage.set(data, forKey: Keys.configuration)
    }

    func assignShortcuts(to entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            storedAssignments: shortcutAssignments
        )

        if result.assignments != shortcutAssignments {
            shortcutAssignments = result.assignments
            persistShortcutAssignments()
        }

        return result.entries
    }

    private func persistShortcutAssignments() {
        guard let data = try? encoder.encode(shortcutAssignments) else {
            return
        }

        storage.set(data, forKey: Keys.shortcutAssignments)
    }
}

struct WindowSwitcherAppEntry: Identifiable {
    let id: String
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let appName: String
    let windowTitle: String?
    let icon: NSImage?
    let windowElement: AXUIElement?
    let isMinimized: Bool
    var shortcutToken: String?

    var displayName: String {
        guard let title = cleanWindowTitle else {
            return appName
        }

        return title
    }

    var displaySubtitle: String? {
        guard let title = cleanWindowTitle,
              title.caseInsensitiveCompare(appName) != .orderedSame
        else {
            return nil
        }

        return appName
    }

    var shortcutDisplay: String? {
        shortcutToken?.uppercased()
    }

    var isWindowEntry: Bool {
        windowElement != nil
    }

    var appIdentifier: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(processIdentifier)"
    }

    private var cleanWindowTitle: String? {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return nil
        }

        return title
    }
}

extension WindowSwitcherAppEntry: Equatable {
    static func == (lhs: WindowSwitcherAppEntry, rhs: WindowSwitcherAppEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.displaySubtitle == rhs.displaySubtitle
            && lhs.shortcutToken == rhs.shortcutToken
    }
}

enum WindowSwitcherShortcutAssignment {
    struct Result {
        let entries: [WindowSwitcherAppEntry]
        let assignments: [String: String]
    }

    private struct Target {
        let index: Int
        let identity: String?
        let preferredToken: String?
    }

    static let singleKeyOrder: [String] = [
        "f", "j", "d", "k", "s", "l", "a", "g", "h",
        "e", "i", "r", "u", "w", "o", "q", "p",
        "c", "m", "v", "n", "x", "b", "z", "t", "y",
    ]

    static func assignShortcuts(to entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        assignShortcuts(to: entries, storedAssignments: [:]).entries
    }

    static func assignShortcuts(
        to entries: [WindowSwitcherAppEntry],
        storedAssignments: [String: String]
    ) -> Result {
        guard !entries.isEmpty else {
            return Result(entries: [], assignments: storedAssignments)
        }

        let targets = assignmentTargets(for: entries)
        let availableTokens = shortcutTokens(count: max(entries.count, singleKeyOrder.count))
        var assignedTokens = Array<String?>(repeating: nil, count: entries.count)
        var usedTokens = Set<String>()

        for target in targets {
            guard let identity = target.identity,
                  let token = storedAssignments[identity],
                  isValidShortcutToken(token),
                  !usedTokens.contains(token)
            else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = target.preferredToken,
                  !usedTokens.contains(token)
            else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = availableTokens.first(where: { !usedTokens.contains($0) }) else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        let assignedEntries = entries.enumerated().map { index, entry in
            var copy = entry
            copy.shortcutToken = assignedTokens[index]
            return copy
        }
        let updatedAssignments = updatedStoredAssignments(
            from: storedAssignments,
            targets: targets,
            assignedTokens: assignedTokens
        )
        return Result(entries: assignedEntries, assignments: updatedAssignments)
    }

    static func shortcutTokens(count: Int) -> [String] {
        guard count > 0 else {
            return []
        }

        var tokens = Array(singleKeyOrder.prefix(count))
        guard tokens.count < count else {
            return tokens
        }

        outer: for first in singleKeyOrder {
            for second in singleKeyOrder {
                tokens.append(first + second)
                if tokens.count == count {
                    break outer
                }
            }
        }

        return tokens
    }

    private static func assignmentTargets(for entries: [WindowSwitcherAppEntry]) -> [Target] {
        var seenApps = Set<String>()

        return entries.enumerated().map { index, entry in
            let appIdentifier = entry.appIdentifier
            let isPrimaryAppEntry = seenApps.insert(appIdentifier).inserted
            return Target(
                index: index,
                identity: isPrimaryAppEntry ? appIdentifier : nil,
                preferredToken: isPrimaryAppEntry ? preferredSingleKeyToken(for: entry) : nil
            )
        }
    }

    private static func updatedStoredAssignments(
        from storedAssignments: [String: String],
        targets: [Target],
        assignedTokens: [String?]
    ) -> [String: String] {
        var assignments = storedAssignments
        var activeTokens = Set<String>()
        var activeIdentities = Set<String>()

        for target in targets {
            guard let identity = target.identity,
                  let token = assignedTokens[target.index]
            else {
                continue
            }

            assignments[identity] = token
            activeTokens.insert(token)
            activeIdentities.insert(identity)
        }

        for (identity, token) in assignments where !activeIdentities.contains(identity) && activeTokens.contains(token) {
            assignments.removeValue(forKey: identity)
        }

        guard assignments.count > 256 else {
            return assignments
        }

        let active = assignments.filter { activeIdentities.contains($0.key) }
        let inactive = assignments
            .filter { !activeIdentities.contains($0.key) }
            .sorted { $0.key < $1.key }
            .prefix(max(0, 256 - active.count))
        return inactive.reduce(into: active) { result, item in
            result[item.key] = item.value
        }
    }

    private static func preferredSingleKeyToken(for entry: WindowSwitcherAppEntry) -> String? {
        let candidates = [
            entry.appName,
            entry.bundleIdentifier?.split(separator: ".").last.map(String.init),
            entry.bundleIdentifier,
        ].compactMap { $0 }

        for candidate in candidates {
            if let token = firstASCIIKey(in: candidate) {
                return token
            }
        }

        return nil
    }

    private static func firstASCIIKey(in text: String) -> String? {
        for scalar in text.lowercased().unicodeScalars {
            guard scalar.value >= 97, scalar.value <= 122 else {
                continue
            }

            return String(Character(scalar))
        }

        return nil
    }

    private static func isValidShortcutToken(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard (1...2).contains(scalars.count) else {
            return false
        }

        return scalars.allSatisfy { scalar in
            scalar.value >= 97 && scalar.value <= 122
        }
    }
}

enum WindowSwitcherShortcutBindingStore {
    static let defaultBinding = ShortcutBinding(
        keyCode: UInt16(kVK_Tab),
        modifiers: .command
    )

    private static let defaultsKey = "shortcut.customization.\(itemID)"

    static var itemID: String {
        "\(WindowSwitcherConstants.pluginID).shortcut.\(WindowSwitcherConstants.shortcutDefinitionID)"
    }

    static func resolvedBinding(userDefaults: UserDefaults = .standard) -> ShortcutBinding? {
        guard let data = userDefaults.data(forKey: defaultsKey) else {
            return defaultBinding
        }

        do {
            let customization = try JSONDecoder().decode(ShortcutCustomization.self, from: data)
            return ShortcutStoreResolve.resolve(customization: customization, defaultBinding: defaultBinding)
        } catch {
            return defaultBinding
        }
    }
}

private enum ShortcutStoreResolve {
    static func resolve(customization: ShortcutCustomization, defaultBinding: ShortcutBinding?) -> ShortcutBinding? {
        switch customization {
        case .inheritDefault:
            return defaultBinding
        case let .custom(binding):
            return binding
        case .cleared:
            return nil
        }
    }
}
