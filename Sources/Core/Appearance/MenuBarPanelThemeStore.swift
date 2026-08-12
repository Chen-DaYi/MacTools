import Combine
import Foundation

@MainActor
final class MenuBarPanelThemeStore: ObservableObject {
    static let shared = MenuBarPanelThemeStore()
    static let didChangeNotification = Notification.Name("MenuBarPanelThemeDidChange")

    static let lightThemeKey = "menuBarPanel.theme.light"
    static let darkThemeKey = "menuBarPanel.theme.dark"
    static let importedThemesKey = "menuBarPanel.theme.imported"

    @Published private(set) var lightThemeID: String
    @Published private(set) var darkThemeID: String
    @Published private(set) var importedThemes: [MenuBarPanelThemeDefinition]

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        lightThemeID = userDefaults.string(forKey: Self.lightThemeKey)
            ?? MenuBarPanelThemeDefinition.systemThemeID
        darkThemeID = userDefaults.string(forKey: Self.darkThemeKey)
            ?? MenuBarPanelThemeDefinition.systemThemeID

        if let data = userDefaults.data(forKey: Self.importedThemesKey),
           let themes = try? JSONDecoder().decode([MenuBarPanelThemeDefinition].self, from: data) {
            importedThemes = themes.filter { $0.origin == .imported }
        } else {
            importedThemes = []
        }

        repairSelectionsIfNeeded()
    }

    var allThemes: [MenuBarPanelThemeDefinition] {
        MenuBarPanelBuiltInThemes.all + importedThemes.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func themes(for appearance: MenuBarPanelThemeAppearance) -> [MenuBarPanelThemeDefinition] {
        allThemes.filter { $0.appearance == appearance }
    }

    func selectedThemeID(for appearance: MenuBarPanelThemeAppearance) -> String {
        appearance == .light ? lightThemeID : darkThemeID
    }

    func definition(withID id: String) -> MenuBarPanelThemeDefinition? {
        allThemes.first { $0.id == id }
    }

    func selectedDefinition(for appearance: MenuBarPanelThemeAppearance) -> MenuBarPanelThemeDefinition? {
        let id = selectedThemeID(for: appearance)
        guard id != MenuBarPanelThemeDefinition.systemThemeID,
              let definition = definition(withID: id),
              definition.appearance == appearance
        else {
            return nil
        }
        return definition
    }

    func selectedThemeName(for appearance: MenuBarPanelThemeAppearance) -> String {
        selectedDefinition(for: appearance)?.name
            ?? AppL10n.settings("panelTheme.systemDefault", defaultValue: "系统默认")
    }

    @discardableResult
    func selectTheme(id: String, for appearance: MenuBarPanelThemeAppearance) -> Bool {
        if id != MenuBarPanelThemeDefinition.systemThemeID {
            guard let definition = definition(withID: id), definition.appearance == appearance else {
                return false
            }
        }

        switch appearance {
        case .light:
            guard lightThemeID != id else { return true }
            lightThemeID = id
            userDefaults.set(id, forKey: Self.lightThemeKey)
        case .dark:
            guard darkThemeID != id else { return true }
            darkThemeID = id
            userDefaults.set(id, forKey: Self.darkThemeKey)
        }
        notifyChange()
        return true
    }

    @discardableResult
    func importTheme(from url: URL) throws -> MenuBarPanelThemeDefinition {
        let theme = try MenuBarPanelThemeImporter.decode(contentsOf: url)
        if let existingIndex = importedThemes.firstIndex(where: { $0.id == theme.id }) {
            importedThemes[existingIndex] = theme
        } else {
            importedThemes.append(theme)
        }
        persistImportedThemes()
        notifyChange()
        return theme
    }

    func deleteImportedTheme(id: String) {
        guard let index = importedThemes.firstIndex(where: { $0.id == id }) else {
            return
        }
        importedThemes.remove(at: index)
        if lightThemeID == id {
            lightThemeID = MenuBarPanelThemeDefinition.systemThemeID
            userDefaults.set(lightThemeID, forKey: Self.lightThemeKey)
        }
        if darkThemeID == id {
            darkThemeID = MenuBarPanelThemeDefinition.systemThemeID
            userDefaults.set(darkThemeID, forKey: Self.darkThemeKey)
        }
        persistImportedThemes()
        notifyChange()
    }

    func isImportedTheme(id: String) -> Bool {
        importedThemes.contains { $0.id == id }
    }

    private func repairSelectionsIfNeeded() {
        let validIDs = Set(allThemes.map(\.id)).union([MenuBarPanelThemeDefinition.systemThemeID])
        if !validIDs.contains(lightThemeID)
            || definition(withID: lightThemeID)?.appearance == .dark {
            lightThemeID = MenuBarPanelThemeDefinition.systemThemeID
            userDefaults.set(lightThemeID, forKey: Self.lightThemeKey)
        }
        if !validIDs.contains(darkThemeID)
            || definition(withID: darkThemeID)?.appearance == .light {
            darkThemeID = MenuBarPanelThemeDefinition.systemThemeID
            userDefaults.set(darkThemeID, forKey: Self.darkThemeKey)
        }
    }

    private func persistImportedThemes() {
        guard let data = try? JSONEncoder().encode(importedThemes) else {
            return
        }
        userDefaults.set(data, forKey: Self.importedThemesKey)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
