import Combine
import Foundation
import MacToolsPluginKit

/// A complete Settings destination, including the currently selected Plugins
/// subpage. Instances are scoped to a single Settings window.
enum SettingsNavigationDestination: Hashable {
    case general
    case about
    case plugins(FeatureSettingsPane)

    var settingsDestination: SettingsDestination {
        switch self {
        case .general:
            .general
        case .about:
            .about
        case .plugins:
            .pluginConfiguration
        }
    }

    var featureSettingsPane: FeatureSettingsPane? {
        guard case let .plugins(pane) = self else {
            return nil
        }

        return pane
    }
}

@MainActor
final class SettingsNavigationCoordinator: ObservableObject {
    private static let maximumHistoryCount = 128

    @Published private(set) var destination: SettingsNavigationDestination

    private(set) var history: [SettingsNavigationDestination]
    private(set) var historyIndex: Int

    private let pluginSettingsLandingPage: () -> FeatureSettingsPane
    private let isPluginConfigurationAvailable: (String) -> Bool
    private let selectPluginSettingsPane: (FeatureSettingsPane) -> Bool

    convenience init(pluginHost: PluginHost) {
        self.init(
            pluginSettingsLandingPage: { pluginHost.pluginSettingsLandingPage() },
            isPluginConfigurationAvailable: { pluginHost.hasPluginConfiguration(pluginID: $0) },
            selectPluginSettingsPane: { pluginHost.selectFeatureSettingsPane($0) }
        )
    }

    init(
        initialDestination: SettingsNavigationDestination = .general,
        pluginSettingsLandingPage: @escaping () -> FeatureSettingsPane = { .marketplace },
        isPluginConfigurationAvailable: @escaping (String) -> Bool = { _ in true },
        selectPluginSettingsPane: @escaping (FeatureSettingsPane) -> Bool = { _ in true }
    ) {
        self.destination = initialDestination
        self.history = [initialDestination]
        self.historyIndex = 0
        self.pluginSettingsLandingPage = pluginSettingsLandingPage
        self.isPluginConfigurationAvailable = isPluginConfigurationAvailable
        self.selectPluginSettingsPane = selectPluginSettingsPane
    }

    var canGoBack: Bool {
        traversableHistoryIndex(startingAt: historyIndex - 1, step: -1) != nil
    }

    var canGoForward: Bool {
        traversableHistoryIndex(startingAt: historyIndex + 1, step: 1) != nil
    }

    func selectSettingsDestination(_ destination: SettingsDestination) {
        guard self.destination.settingsDestination != destination else {
            return
        }

        switch destination {
        case .general:
            navigate(to: .general)
        case .about:
            navigate(to: .about)
        case .pluginConfiguration:
            navigate(to: .plugins(pluginSettingsLandingPage()))
        }
    }

    func navigate(to destination: SettingsNavigationDestination) {
        guard isAvailable(destination), destination != self.destination else {
            return
        }

        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }

        history.append(destination)
        if history.count > Self.maximumHistoryCount {
            history.removeFirst(history.count - Self.maximumHistoryCount)
        }
        historyIndex = history.count - 1
        activate(destination)
    }

    func goBack() {
        traverseHistory(startingAt: historyIndex - 1, step: -1)
    }

    func goForward() {
        traverseHistory(startingAt: historyIndex + 1, step: 1)
    }

    func reconcileCurrentDestinationAvailability() {
        guard !isAvailable(destination) else {
            return
        }

        navigate(to: .plugins(.marketplace))
    }

    private func traverseHistory(startingAt index: Int, step: Int) {
        guard let index = traversableHistoryIndex(startingAt: index, step: step) else {
            return
        }

        let destination = history[index]
        historyIndex = index
        activate(destination)
    }

    private func traversableHistoryIndex(startingAt index: Int, step: Int) -> Int? {
        var index = index

        while history.indices.contains(index) {
            let candidate = history[index]
            if isAvailable(candidate), candidate != destination {
                return index
            }

            index += step
        }

        return nil
    }

    private func isAvailable(_ destination: SettingsNavigationDestination) -> Bool {
        guard case let .plugins(.configuration(pluginID)) = destination else {
            return true
        }

        return isPluginConfigurationAvailable(pluginID)
    }

    private func activate(_ destination: SettingsNavigationDestination) {
        if let pane = destination.featureSettingsPane {
            _ = selectPluginSettingsPane(pane)
        }

        self.destination = destination
    }
}
