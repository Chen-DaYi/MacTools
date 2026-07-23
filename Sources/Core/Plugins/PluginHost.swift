import Combine
import Foundation
import SwiftUI
import MacToolsPluginKit

enum FeatureSettingsPane: Hashable {
    case dashboardLayout
    case featurePanelLayout
    case marketplace
    case configuration(String)
}

enum SettingsPresentationRequest: Equatable {
    case settings
    case pluginMarketplace
    case pluginConfiguration(String)
}

private extension FeatureSettingsPane {
    init(landingPage: PluginSettingsLandingPage) {
        switch landingPage {
        case .dashboard:
            self = .dashboardLayout
        case .featurePanel:
            self = .featurePanelLayout
        case .marketplace:
            self = .marketplace
        }
    }

    var landingPage: PluginSettingsLandingPage? {
        switch self {
        case .dashboardLayout:
            .dashboard
        case .featurePanelLayout:
            .featurePanel
        case .marketplace:
            .marketplace
        case .configuration:
            nil
        }
    }
}

struct PluginHostCapabilities: Equatable, Sendable {
    let supportsDashboard: Bool
    let supportsFeaturePanel: Bool
    let hasCustomConfiguration: Bool

    var supportedSurfaces: Set<PluginDisplaySurface> {
        var surfaces: Set<PluginDisplaySurface> = []
        if supportsDashboard {
            surfaces.insert(.dashboard)
        }
        if supportsFeaturePanel {
            surfaces.insert(.featurePanel)
        }
        return surfaces
    }
}

struct PluginSurfaceLayoutItem: Identifiable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let capabilities: PluginHostCapabilities
    let isVisible: Bool
    let isActive: Bool
    let canUninstall: Bool
    let category: String?
    let releaseChannel: String?
}

struct AppShortcutSettingsItem: Equatable {
    let bindingText: String
    let canClear: Bool
    let errorMessage: String?
}

struct PluginAutomaticUpdateStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case checking
        case updating
        case completed
        case failed
    }

    let phase: Phase
    let pluginIDs: [String]
    let message: String?

    static let idle = PluginAutomaticUpdateStatus(
        phase: .idle,
        pluginIDs: [],
        message: nil
    )

    var isActive: Bool {
        phase == .checking || phase == .updating
    }

    var isVisible: Bool {
        phase != .idle
    }

    func isUpdatingPlugin(id: String) -> Bool {
        phase == .updating && pluginIDs.contains(id)
    }

    var title: String {
        switch phase {
        case .idle:
            return ""
        case .checking:
            return AppL10n.plugins("plugin.autoUpdate.title.checking", defaultValue: "正在检查插件更新")
        case .updating:
            return AppL10n.plugins("plugin.autoUpdate.title.updating", defaultValue: "正在更新插件")
        case .completed:
            return AppL10n.plugins("plugin.autoUpdate.title.completed", defaultValue: "插件已更新")
        case .failed:
            return AppL10n.plugins("plugin.autoUpdate.title.failed", defaultValue: "插件自动更新失败")
        }
    }

    var detailText: String {
        if let message {
            return message
        }

        switch phase {
        case .idle:
            return ""
        case .checking:
            return AppL10n.plugins("plugin.autoUpdate.detail.checking", defaultValue: "新版首次启动时会先检查已安装插件。")
        case .updating:
            return AppL10n.pluginsFormat(
                "plugin.autoUpdate.detail.updatingFormat",
                defaultValue: "正在更新 %d 个已安装插件，完成后会继续加载。",
                pluginIDs.count
            )
        case .completed:
            return pluginIDs.isEmpty
                ? AppL10n.plugins("plugin.autoUpdate.detail.noUpdates", defaultValue: "已是最新版本。")
                : AppL10n.pluginsFormat("plugin.autoUpdate.detail.completedFormat", defaultValue: "已更新 %d 个插件。", pluginIDs.count)
        case .failed:
            return AppL10n.plugins("plugin.autoUpdate.detail.failed", defaultValue: "稍后可在此页面重试。")
        }
    }
}

struct PluginAutomaticUpdateVersionStore {
    private enum DefaultsKey {
        static let lastCheckedAppVersion = "plugins.dynamic.lastAutomaticUpdateAppVersion"
    }

    var userDefaults: UserDefaults = .standard

    func needsAutomaticUpdateCheck(currentAppVersion: String) -> Bool {
        guard !currentAppVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return userDefaults.string(forKey: DefaultsKey.lastCheckedAppVersion) != currentAppVersion
    }

    func markAutomaticUpdateChecked(currentAppVersion: String) {
        userDefaults.set(currentAppVersion, forKey: DefaultsKey.lastCheckedAppVersion)
    }
}

@MainActor
final class PluginHost: ObservableObject {
    private enum AppShortcut {
        static let openSettingsID = "app.open-settings"
    }

    private struct PluginDescriptor {
        let metadata: PluginMetadata
        let plugin: any MacToolsPlugin
        let capabilities: PluginHostCapabilities

        var hasPrimaryPanel: Bool {
            capabilities.supportsFeaturePanel
        }

        var hasComponentPanel: Bool {
            capabilities.supportsDashboard
        }

        var hasConfiguration: Bool {
            capabilities.hasCustomConfiguration
        }
    }

    private struct ShortcutDescriptor {
        let itemID: String
        let pluginID: String
        let pluginTitle: String
        let definition: PluginShortcutDefinition
        let plugin: any MacToolsPlugin
    }

    private let builtInPlugins: [any MacToolsPlugin]
    private let shortcutStore: ShortcutStore
    private let pluginDisplayPreferencesStore: PluginDisplayPreferencesStore
    private let preferencesBackupStore: any PreferencesBackupApplicationStoring
    private let globalShortcutManager: GlobalShortcutManager
    private let displayConfigurationObserver: (any DisplayConfigurationObserving)?
    private let accessibilityPermissionObserver: (any AccessibilityPermissionObserving)?
    private let applicationActivityObserver: (any ApplicationActivityObserving)?
    private let displayTopologyRefreshDelay: Duration
    private let pluginStateChangeRebuildDelay: Duration
    let dynamicPluginManager: DynamicPluginManager?
    private let pluginCatalogManager: PluginCatalogManager?

    private var dynamicPlugins: [any MacToolsPlugin] = []
    private var dynamicPluginCapabilitiesByID: [String: PluginPackageManifest.Capabilities] = [:]
    private var dynamicPluginCategoriesByID: [String: String?] = [:]
    private var dynamicPluginReleaseChannelsByID: [String: String?] = [:]
    private var dynamicPluginManifestsByID: [String: PluginPackageManifest] = [:]
    private var shortcutErrors: [String: String] = [:]
    private var openSettingsShortcutError: String?
    private var componentViewCache: [String: PluginComponentViewItem] = [:]
    private var configurationViewCache: [String: PluginConfigurationViewItem] = [:]
    private var visiblePanelSurfaces: Set<PluginPanelSurface> = []
    private var visiblePanelSurfacePluginIDs: [PluginPanelSurface: Set<String>] = [:]
    private var isolatedPluginFailures: [String: String] = [:]
    private var isHandlingPluginAction = false
    private var didLoadDynamicPlugins = false
    private var displayTopologyRefreshTask: Task<Void, Never>?
    private var pluginStateChangeRebuildTask: Task<Void, Never>?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var applicationActivityState: PluginApplicationActivityState
    private var dirtyPluginIDs: Set<String> = []
    private var cachedPanelStatesByID: [String: PluginPanelState] = [:]
    private var cachedPrimaryPanelIndicatorsByID: [String: PluginPrimaryPanelIndicator] = [:]
    private var evaluatedPrimaryPanelIndicatorPluginIDs: Set<String> = []
    private var cachedComponentStatesByID: [String: PluginComponentState] = [:]
    private var loggedCapabilityMismatchPluginIDs: Set<String> = []
    private var builtInCapabilitiesByID: [String: PluginHostCapabilities] = [:]
    private var dynamicResolvedCapabilitiesByID: [String: PluginHostCapabilities] = [:]

    @Published private(set) var panelItems: [PluginPanelItem] = []
    @Published private(set) var primaryPanelIndicatorsByID: [String: PluginPrimaryPanelIndicator] = [:]
    @Published private(set) var componentItems: [PluginComponentItem] = []
    // Legacy management projection retained for failure isolation and older
    // tests. Layout settings use the per-surface order projections below.
    @Published private(set) var featureManagementItems: [PluginFeatureManagementItem] = []
    @Published private(set) var dashboardLayoutItems: [PluginSurfaceLayoutItem] = []
    @Published private(set) var dashboardHiddenLayoutItems: [PluginSurfaceLayoutItem] = []
    @Published private(set) var featurePanelLayoutItems: [PluginSurfaceLayoutItem] = []
    @Published private(set) var featurePanelHiddenLayoutItems: [PluginSurfaceLayoutItem] = []
    @Published private(set) var pluginConfigurationItems: [PluginConfigurationItem] = []
    @Published private(set) var permissionCards: [PluginPermissionCard] = []
    @Published private(set) var settingsCards: [PluginSettingsCard] = []
    @Published private(set) var shortcutItems: [ShortcutSettingsItem] = []
    @Published private(set) var openSettingsShortcut = AppShortcutSettingsItem(
        bindingText: ShortcutFormatter.displayString(for: nil),
        canClear: false,
        errorMessage: nil
    )
    @Published private(set) var pluginManagementItems: [PluginManagementItem] = []
    @Published private(set) var pluginCatalogStatus: PluginCatalogStatus = .unavailable
    @Published private(set) var automaticPluginUpdateStatus: PluginAutomaticUpdateStatus = .idle
    @Published private(set) var hasActivePlugin = false
    @Published private(set) var localizationRevision = 0

    /// AppWindowRouter installs this while the application is running. The
    /// host emits presentation requests but never retains Settings-window
    /// navigation state.
    var settingsPresentationHandler: ((SettingsPresentationRequest) -> Void)?

    /// Injected by `MenuBarStatusItemController`; returns the status-item button frame in screen coordinates.
    var statusItemButtonFrameProvider: (() -> NSRect?)? = nil {
        didSet {
            configureHostStatusItemCallbacks(for: activePlugins)
        }
    }
    var resetStatusItemPosition: (() -> Void)? = nil {
        didSet {
            configureHostStatusItemCallbacks(for: activePlugins)
        }
    }

    convenience init(
        loadDynamicPluginsOnInit: Bool = true,
        preferencesBackupStore: any PreferencesBackupApplicationStoring
    ) {
        let dynamicPluginManager = DynamicPluginManager()
        let pluginCatalogManager = PluginCatalogManager.live(dynamicPluginManager: dynamicPluginManager)
        self.init(
            plugins: BuiltInPluginRegistry().makePlugins(),
            dynamicPluginManager: dynamicPluginManager,
            pluginCatalogManager: pluginCatalogManager,
            shortcutStore: ShortcutStore(),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(),
            preferencesBackupStore: preferencesBackupStore,
            globalShortcutManager: GlobalShortcutManager(),
            displayConfigurationObserver: SystemDisplayConfigurationObserver(),
            accessibilityPermissionObserver: AccessibilityPermissionObserver(),
            applicationActivityObserver: SystemApplicationActivityObserver(),
            loadDynamicPluginsOnInit: loadDynamicPluginsOnInit
        )
    }

    init(
        plugins: [any MacToolsPlugin],
        dynamicPluginManager: DynamicPluginManager? = nil,
        pluginCatalogManager: PluginCatalogManager? = nil,
        shortcutStore: ShortcutStore,
        pluginDisplayPreferencesStore: PluginDisplayPreferencesStore,
        preferencesBackupStore: any PreferencesBackupApplicationStoring,
        globalShortcutManager: GlobalShortcutManager,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        accessibilityPermissionObserver: (any AccessibilityPermissionObserving)? = nil,
        applicationActivityObserver: (any ApplicationActivityObserving)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180),
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80),
        loadDynamicPluginsOnInit: Bool = true
    ) {
        self.builtInPlugins = plugins.sorted {
            if $0.metadata.order == $1.metadata.order {
                return $0.metadata.title.localizedCompare($1.metadata.title) == .orderedAscending
            }

            return $0.metadata.order < $1.metadata.order
        }
        self.shortcutStore = shortcutStore
        self.pluginDisplayPreferencesStore = pluginDisplayPreferencesStore
        self.preferencesBackupStore = preferencesBackupStore
        self.globalShortcutManager = globalShortcutManager
        self.displayConfigurationObserver = displayConfigurationObserver
        self.accessibilityPermissionObserver = accessibilityPermissionObserver
        self.applicationActivityObserver = applicationActivityObserver
        self.applicationActivityState = applicationActivityObserver?.state ?? .interactive
        self.displayTopologyRefreshDelay = displayTopologyRefreshDelay
        self.pluginStateChangeRebuildDelay = pluginStateChangeRebuildDelay
        self.dynamicPluginManager = dynamicPluginManager
        self.pluginCatalogManager = pluginCatalogManager

        configureCallbacks(for: self.builtInPlugins)

        if let dynamicPluginManager {
            // The retired global checkbox becomes hidden on every surface
            // the plugin supports. Consume the package-store marker before
            // loading dynamic code, but do not hold or deactivate packages:
            // surface visibility is intentionally independent of lifecycle.
            let legacyHiddenPluginIDs = dynamicPluginManager.legacyHiddenPluginIDs()
            if pluginDisplayPreferencesStore.addLegacyHiddenPluginIDs(legacyHiddenPluginIDs) {
                dynamicPluginManager.clearLegacyHiddenPluginIDs()
            } else {
                // An unknown future display payload must remain untouched until
                // the user makes an explicit edit. Acknowledge the package-store
                // marker after that edit durably captures the staged state, so a
                // later launch cannot reapply stale legacy visibility.
                pluginDisplayPreferencesStore.onNextSuccessfulPersistence = {
                    [weak dynamicPluginManager] in
                    dynamicPluginManager?.clearLegacyHiddenPluginIDs()
                }
            }
            if loadDynamicPluginsOnInit {
                self.dynamicPlugins = dynamicPluginManager.loadInstalledPlugins()
                self.didLoadDynamicPlugins = true
            } else {
                dynamicPluginManager.prepareInstalledPluginsWithoutLoading()
            }
            self.dynamicPluginCapabilitiesByID = dynamicPluginManager.installedCapabilitiesByID()
            self.dynamicPluginCategoriesByID = dynamicPluginManager.installedCategoriesByID()
            self.dynamicPluginReleaseChannelsByID = dynamicPluginManager.installedReleaseChannelsByID()
            self.dynamicPluginManifestsByID = dynamicPluginManager.installedManifestsByID()
            self.pluginManagementItems = dynamicPluginManager.pluginManagementItems
            self.pluginCatalogStatus = pluginCatalogManager?.status ?? .unavailable
            configureCallbacks(for: self.dynamicPlugins)
            dynamicPluginManager.onPluginsChanged = { [weak self] plugins in
                self?.replaceDynamicPlugins(plugins)
            }
        }

        self.globalShortcutManager.onShortcutTriggered = { [weak self] shortcutID in
            self?.handleShortcutTrigger(shortcutID: shortcutID)
        }
        self.globalShortcutManager.onShortcutReleased = { [weak self] shortcutID in
            self?.handleShortcutRelease(shortcutID: shortcutID)
        }

        self.displayConfigurationObserver?.onConfigurationChange = { [weak self] in
            self?.scheduleDisplayTopologyRefresh()
        }

        self.accessibilityPermissionObserver?.onPermissionChange = { [weak self] in
            self?.refreshAccessibilityPermissionNow()
        }

        self.applicationActivityObserver?.onStateChange = { [weak self] state in
            self?.handleApplicationActivityStateChange(state)
        }

        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalization()
                }
            }

        refreshAll()
    }

    isolated deinit {
        displayTopologyRefreshTask?.cancel()
        pluginStateChangeRebuildTask?.cancel()
        runtimeLocaleCancellable?.cancel()
    }

    func deactivateAllPlugins(reason: PluginDeactivationReason = .hostShutdown) {
        pluginStateChangeRebuildTask?.cancel()
        pluginStateChangeRebuildTask = nil
        hideAllPanelSurfaces()

        for plugin in activePlugins {
            guardPluginCall(plugin, operation: "deactivate plugin") {
                plugin.deactivate(reason: reason)
            }
        }
    }

    func refreshAll() {
        handlePluginAction(rebuildAfterAction: false) {
            for plugin in activePlugins {
                guardPluginCall(plugin, operation: "refresh") {
                    plugin.refresh()
                }
            }
        }

        syncGlobalShortcuts()
        rebuildDerivedState()
    }

    func makePreferencesBackup() -> PreferencesBackup {
        let shortcutDescriptors = shortcutDescriptors()

        return PreferencesBackup(
            application: preferencesBackupStore.applicationPreferences(),
            pluginDisplay: pluginDisplayPreferencesStore.backupSnapshot(
                defaultPluginIDs: defaultPluginIDs,
                dashboardDefaultPluginIDs: defaultPluginIDs(for: .dashboard),
                featurePanelDefaultPluginIDs: defaultPluginIDs(for: .featurePanel)
            ),
            shortcutCustomizations: shortcutStore.customizations(
                for: [AppShortcut.openSettingsID] + shortcutDescriptors.map(\.itemID)
            ),
            pluginPreferences: portablePluginPreferences()
        )
    }

    func preferencesImportPreview(for backup: PreferencesBackup) throws -> PreferencesImportPreview {
        try PreferencesImportPreview.make(
            backup: backup,
            availablePluginIDs: Set(defaultPluginIDs),
            availableShortcutIDs: Set([AppShortcut.openSettingsID] + shortcutDescriptors().map(\.itemID)),
            pluginManagementItems: pluginManagementItems,
            applicationPreferencesAreValid: preferencesBackupStore.validates
        )
    }

    func importPreferences(
        _ backup: PreferencesBackup,
        installingMissingPluginIDs requestedPluginIDs: Set<String>
    ) async throws -> PreferencesImportResult {
        let preview = try preferencesImportPreview(for: backup)
        let installablePluginIDs = Set(preview.installablePlugins.map(\.id))
        var installedPluginIDs: [String] = []
        var pluginInstallationFailures: [String: String] = [:]

        for pluginID in requestedPluginIDs.intersection(installablePluginIDs).sorted() {
            do {
                try await installPluginFromCatalog(pluginID: pluginID)
                installedPluginIDs.append(pluginID)
            } catch {
                pluginInstallationFailures[pluginID] = error.localizedDescription
            }
        }

        if !installedPluginIDs.isEmpty {
            loadDynamicPluginsIfNeeded()
        }

        var result = try importPreferences(backup)
        result = PreferencesImportResult(
            installedPluginIDs: installedPluginIDs,
            pluginInstallationFailures: pluginInstallationFailures,
            shortcutErrors: result.shortcutErrors
        )
        return result
    }

    func importPreferences(_ backup: PreferencesBackup) throws -> PreferencesImportResult {
        _ = try preferencesImportPreview(for: backup)
        preferencesBackupStore.apply(backup.application)

        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            backup.pluginDisplay.orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            backup.pluginDisplay.dashboardOrderedPluginIDs ?? backup.pluginDisplay.orderedPluginIDs,
            for: .dashboard,
            defaultPluginIDs: defaultPluginIDs(for: .dashboard)
        )
        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            backup.pluginDisplay.featurePanelOrderedPluginIDs ?? backup.pluginDisplay.orderedPluginIDs,
            for: .featurePanel,
            defaultPluginIDs: defaultPluginIDs(for: .featurePanel)
        )
        // A legacy backup has one global checkbox. Map it to both supported
        // surfaces; current backups restore the two independent values.
        pluginDisplayPreferencesStore.setHiddenPluginIDs(
            Set(backup.pluginDisplay.dashboardHiddenPluginIDs ?? backup.pluginDisplay.hiddenPluginIDs),
            for: .dashboard,
            defaultPluginIDs: defaultPluginIDs(for: .dashboard)
        )
        pluginDisplayPreferencesStore.setHiddenPluginIDs(
            Set(backup.pluginDisplay.featurePanelHiddenPluginIDs ?? backup.pluginDisplay.hiddenPluginIDs),
            for: .featurePanel,
            defaultPluginIDs: defaultPluginIDs(for: .featurePanel)
        )

        restorePortablePluginPreferences(backup.pluginPreferences)
        let shortcutErrors = applyImportedShortcutCustomizations(backup.shortcutCustomizations)

        rebuildDerivedState()
        syncGlobalShortcuts()
        return PreferencesImportResult(
            installedPluginIDs: [],
            pluginInstallationFailures: [:],
            shortcutErrors: shortcutErrors
        )
    }

    /// Rebuild language-dependent host data without refreshing or reactivating
    /// plugins, which keeps active plugin sessions and external side effects intact.
    func refreshLocalization() {
        for plugin in activePlugins {
            guard let localizationRefreshing = plugin as? any PluginRuntimeLocalizationRefreshing else {
                continue
            }

            guardPluginCall(plugin, operation: "refresh localization") {
                localizationRefreshing.refreshLocalization()
            }
        }
        componentViewCache.removeAll()
        configurationViewCache.removeAll()
        cachedPanelStatesByID.removeAll()
        cachedComponentStatesByID.removeAll()
        syncPluginManagementState()
        localizationRevision &+= 1
        rebuildDerivedState()
    }

    func refreshDisplayTopology() {
        displayTopologyRefreshTask?.cancel()
        refreshDisplayTopologyNow()
    }

    func isSwitchOn(for pluginID: String) -> Bool {
        panelItems.first(where: { $0.id == pluginID })?.isOn ?? false
    }

    func setSwitchValue(_ isOn: Bool, for pluginID: String) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set switch") {
                primaryPanel.handleAction(.setSwitch(isOn))
            }
        }
    }

    func setDisclosureExpanded(_ isExpanded: Bool, for pluginID: String) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set disclosure") {
                primaryPanel.handleAction(.setDisclosureExpanded(isExpanded))
            }
        }
    }

    func setPanelSelectionValue(
        _ optionID: String,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set selection") {
                primaryPanel.handleAction(.setSelection(controlID: controlID, optionID: optionID))
            }
        }
    }

    func setPanelNavigationSelectionValue(
        _ optionID: String,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set navigation selection") {
                primaryPanel.handleAction(
                    .setNavigationSelection(controlID: controlID, optionID: optionID)
                )
            }
        }
    }

    func clearPanelNavigationSelection(
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "clear navigation selection") {
                primaryPanel.handleAction(.clearNavigationSelection(controlID: controlID))
            }
        }
    }

    func setPanelDateValue(
        _ date: Date,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set date") {
                primaryPanel.handleAction(.setDate(controlID: controlID, value: date))
            }
        }
    }

    func setPanelSliderValue(
        _ value: Double,
        controlID: String,
        for pluginID: String,
        phase: PluginPanelAction.SliderPhase
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        let isolatedPluginCountAtStart = isolatedPluginFailures.count
        handlePluginAction(rebuildAfterAction: phase == .ended) {
            guardPluginCall(plugin, operation: "set slider") {
                primaryPanel.handleAction(.setSlider(controlID: controlID, value: value, phase: phase))
            }
        }

        if phase == .changed, isolatedPluginFailures.count > isolatedPluginCountAtStart {
            rebuildDerivedState()
        }
    }

    func invokePanelAction(controlID: String, for pluginID: String) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "invoke panel action") {
                primaryPanel.handleAction(.invokeAction(controlID: controlID))
            }
        }
    }

    func performSettingsAction(pluginID: String, actionID: String) {
        guard let plugin = corePlugin(for: pluginID) else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "settings action") {
                plugin.handleSettingsAction(id: actionID)
            }
        }
    }

    func performPermissionAction(pluginID: String, permissionID: String) {
        guard let plugin = corePlugin(for: pluginID) else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "permission action") {
                plugin.handlePermissionAction(id: permissionID)
            }
        }
    }

    func setShortcutBinding(_ binding: ShortcutBinding, for shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(.custom(binding), for: descriptor)
    }

    func setShortcutBindingAndReturnError(_ binding: ShortcutBinding, for shortcutID: String) -> String? {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return AppL10n.plugins("plugin.shortcut.unavailable", defaultValue: "快捷键不可用。")
        }

        return applyShortcutCustomization(.custom(binding), for: descriptor)
    }

    func setOpenSettingsShortcutBindingAndReturnError(_ binding: ShortcutBinding) -> String? {
        do {
            try validateOpenSettingsShortcut(binding)
            shortcutStore.setCustomization(.custom(binding), for: AppShortcut.openSettingsID)
            openSettingsShortcutError = nil
            rebuildDerivedState()
            syncGlobalShortcuts()
            return nil
        } catch let error as ShortcutValidationError {
            openSettingsShortcutError = error.localizedDescription
            rebuildDerivedState()
            return error.localizedDescription
        } catch {
            openSettingsShortcutError = error.localizedDescription
            rebuildDerivedState()
            return error.localizedDescription
        }
    }

    func clearOpenSettingsShortcut() {
        shortcutStore.setCustomization(.cleared, for: AppShortcut.openSettingsID)
        openSettingsShortcutError = nil
        rebuildDerivedState()
        syncGlobalShortcuts()
    }

    func clearOpenSettingsShortcutError() {
        guard openSettingsShortcutError != nil else {
            return
        }

        openSettingsShortcutError = nil
        rebuildDerivedState()
    }

    func clearShortcut(for shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(.cleared, for: descriptor)
    }

    func resetShortcut(for shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(.inheritDefault, for: descriptor)
    }

    func presentPluginConfiguration(pluginID: String) {
        rebuildDerivedState()

        guard pluginConfigurationItems.contains(where: { $0.id == pluginID }) else {
            return
        }

        settingsPresentationHandler?(.pluginConfiguration(pluginID))
    }

    func presentPluginMarketplace() {
        settingsPresentationHandler?(.pluginMarketplace)
    }

    /// Chooses the entry page for a normal Plugins-tab selection. Explicit
    /// navigation to Marketplace or a plugin configuration bypasses this so
    /// the requested destination is always respected.
    func pluginSettingsLandingPage() -> FeatureSettingsPane {
        let dashboardIsAvailable = !dashboardLayoutItems.isEmpty || !dashboardHiddenLayoutItems.isEmpty
        let featurePanelIsAvailable = !featurePanelLayoutItems.isEmpty || !featurePanelHiddenLayoutItems.isEmpty

        let landingPage: PluginSettingsLandingPage
        if !dashboardIsAvailable && !featurePanelIsAvailable {
            landingPage = .marketplace
        } else if let savedPage = pluginDisplayPreferencesStore.lastPluginSettingsLandingPage(),
                  isAvailable(savedPage, dashboardIsAvailable: dashboardIsAvailable, featurePanelIsAvailable: featurePanelIsAvailable) {
            landingPage = savedPage
        } else if dashboardIsAvailable {
            landingPage = .dashboard
        } else {
            landingPage = .featurePanel
        }

        // This automatic route must not replace the user's saved choice. For
        // example, temporarily having only settings-only plugins should not
        // make Marketplace their permanent landing page after they install a
        // layout-capable plugin again.
        return FeatureSettingsPane(landingPage: landingPage)
    }

    @discardableResult
    func selectFeatureSettingsPane(_ pane: FeatureSettingsPane) -> Bool {
        switch pane {
        case .dashboardLayout, .featurePanelLayout, .marketplace:
            if let landingPage = pane.landingPage {
                pluginDisplayPreferencesStore.setLastPluginSettingsLandingPage(landingPage)
            }
            return true
        case let .configuration(pluginID):
            guard pluginConfigurationItems.contains(where: { $0.id == pluginID }) else {
                return false
            }

            return true
        }
    }

    func hasPluginConfiguration(pluginID: String) -> Bool {
        pluginConfigurationItems.contains(where: { $0.id == pluginID })
    }

    func clearShortcutError(for shortcutID: String) {
        guard shortcutErrors.removeValue(forKey: shortcutID) != nil else {
            return
        }

        rebuildDerivedState()
    }

    /// Moves a plugin within a surface's visible order while leaving hidden
    /// plugins in their remembered slots.
    func movePlugin(id pluginID: String, toOffset targetOffset: Int, on surface: PluginDisplaySurface) {
        let defaultPluginIDs = defaultPluginIDs(for: surface)
        var orderedPluginIDs = visiblePluginIDs(for: surface)

        guard let currentIndex = orderedPluginIDs.firstIndex(of: pluginID) else {
            return
        }

        let clampedOffset = min(max(targetOffset, 0), orderedPluginIDs.count)
        guard currentIndex != clampedOffset, currentIndex + 1 != clampedOffset else {
            return
        }

        orderedPluginIDs.move(
            fromOffsets: IndexSet(integer: currentIndex),
            toOffset: clampedOffset
        )
        pluginDisplayPreferencesStore.setVisiblePluginIDs(
            orderedPluginIDs,
            for: surface,
            defaultPluginIDs: defaultPluginIDs
        )
        rebuildDerivedState()
    }

    func setPluginVisible(_ isVisible: Bool, id pluginID: String, on surface: PluginDisplaySurface) {
        pluginDisplayPreferencesStore.setPluginVisible(
            isVisible,
            pluginID: pluginID,
            on: surface,
            defaultPluginIDs: defaultPluginIDs(for: surface)
        )
        rebuildDerivedState()
    }

    func resetPluginOrder(on surface: PluginDisplaySurface) {
        pluginDisplayPreferencesStore.resetOrder(
            for: surface,
            defaultPluginIDs: defaultPluginIDs(for: surface)
        )
        rebuildDerivedState()
    }

    func canMoveFeatureManagementItem(id pluginID: String, by offset: Int) -> Bool {
        let orderedPluginIDs = orderedPluginIDs()

        guard let currentIndex = orderedPluginIDs.firstIndex(of: pluginID) else {
            return false
        }

        let targetIndex = currentIndex + offset
        return orderedPluginIDs.indices.contains(targetIndex)
    }

    func moveFeatureManagementItem(id pluginID: String, by offset: Int) {
        var orderedPluginIDs = orderedPluginIDs()

        guard let currentIndex = orderedPluginIDs.firstIndex(of: pluginID) else {
            return
        }

        let targetIndex = currentIndex + offset

        guard orderedPluginIDs.indices.contains(targetIndex) else {
            return
        }

        let movedPluginID = orderedPluginIDs.remove(at: currentIndex)
        orderedPluginIDs.insert(movedPluginID, at: targetIndex)

        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        rebuildDerivedState()
    }

    func moveFeatureManagementItem(id pluginID: String, toOffset targetOffset: Int) {
        var orderedPluginIDs = orderedPluginIDs()

        guard let currentIndex = orderedPluginIDs.firstIndex(of: pluginID) else {
            return
        }

        let clampedOffset = min(max(targetOffset, 0), orderedPluginIDs.count)

        guard currentIndex != clampedOffset, currentIndex + 1 != clampedOffset else {
            return
        }

        orderedPluginIDs.move(
            fromOffsets: IndexSet(integer: currentIndex),
            toOffset: clampedOffset
        )

        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        rebuildDerivedState()
    }

    func moveFeatureManagementItems(fromOffsets: IndexSet, toOffset: Int) {
        var orderedPluginIDs = orderedPluginIDs()
        orderedPluginIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)

        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        rebuildDerivedState()
    }

    func componentViewItem(for itemID: String, dismiss: @escaping () -> Void) -> PluginComponentViewItem {
        if let cachedItem = componentViewCache[itemID] {
            return cachedItem
        }

        guard let plugin = corePlugin(for: itemID),
              let componentPanel = plugin.componentPanel
        else {
            let item = PluginComponentViewItem(id: itemID, content: AnyView(EmptyView()))
            componentViewCache[itemID] = item
            return item
        }

        let context = PluginComponentContext(
            pluginID: itemID,
            dismiss: dismiss,
            isPanelVisible: true
        )
        let content = guardedValue(
            for: plugin,
            operation: "make component view",
            componentPanel.makeView(context: context)
        ) ?? AnyView(EmptyView())

        let item = PluginComponentViewItem(
            id: itemID,
            content: AnyView(content.id(localizationRevision))
        )
        componentViewCache[itemID] = item
        if isPluginIsolated(plugin) {
            rebuildDerivedState()
        }
        return item
    }

    func setPanelSurface(_ surface: PluginPanelSurface, visible isVisible: Bool) {
        if isVisible {
            visiblePanelSurfaces.insert(surface)
        } else {
            visiblePanelSurfaces.remove(surface)
        }

        let visiblePluginIDs = isVisible ? pluginIDs(for: surface) : []
        updateVisiblePanelSurface(surface, visiblePluginIDs: visiblePluginIDs)
    }

    func isComponentViewCached(for itemID: String) -> Bool {
        componentViewCache[itemID] != nil
    }

    func prewarmComponentViews(dismiss: @escaping () -> Void) {
        for item in componentItems {
            _ = componentViewItem(for: item.id, dismiss: dismiss)
        }
    }

    func pluginConfigurationViewItem(for pluginID: String) -> PluginConfigurationViewItem {
        if let cachedItem = configurationViewCache[pluginID] {
            return cachedItem
        }

        let configurations = orderedPluginDescriptors()
            .filter { $0.metadata.id == pluginID && $0.hasConfiguration }
            .compactMap { descriptor -> (any MacToolsPlugin, PluginConfiguration)? in
                guard let configuration = guardedOptionalValue(
                    for: descriptor.plugin,
                    operation: "read plugin configuration",
                    descriptor.plugin.configuration
                ) else {
                    return nil
                }

                return (descriptor.plugin, configuration)
            }

        guard corePlugin(for: pluginID) != nil else {
            rebuildDerivedState()
            return PluginConfigurationViewItem(id: pluginID, content: AnyView(EmptyView()))
        }

        let context = PluginConfigurationContext(
            pluginID: pluginID,
            shortcutItems: shortcutItems.filter { $0.pluginID == pluginID },
            recordShortcut: { [weak self] itemID, binding in
                self?.clearShortcutError(for: itemID)
                return self?.setShortcutBindingAndReturnError(binding, for: itemID)
            },
            beginShortcutRecording: { [weak self] itemID in
                self?.clearShortcutError(for: itemID)
            },
            clearShortcut: { [weak self] itemID in
                self?.clearShortcutError(for: itemID)
                self?.clearShortcut(for: itemID)
            },
            resetShortcut: { [weak self] itemID in
                self?.clearShortcutError(for: itemID)
                self?.resetShortcut(for: itemID)
            }
        )
        let content: AnyView

        switch configurations.count {
        case 0:
            content = AnyView(EmptyView())
        case 1:
            content = guardedConfigurationView(
                for: configurations[0].0,
                configuration: configurations[0].1,
                context: context
            )
        default:
            let views = configurations.map {
                guardedConfigurationView(
                    for: $0.0,
                    configuration: $0.1,
                    context: context
                )
            }
            content = AnyView(
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Swift.Array(views.enumerated()), id: \.offset) { entry in
                        entry.element
                    }
                }
            )
        }

        guard corePlugin(for: pluginID) != nil else {
            rebuildDerivedState()
            return PluginConfigurationViewItem(id: pluginID, content: AnyView(EmptyView()))
        }

        let item = PluginConfigurationViewItem(
            id: pluginID,
            content: AnyView(content.id(localizationRevision))
        )
        configurationViewCache[pluginID] = item
        return item
    }

    func discardComponentViews() {
        componentViewCache.removeAll()
    }

    func refreshPluginCatalog() async {
        await pluginCatalogManager?.refreshCatalog()
        syncPluginManagementState()
    }

    func loadDynamicPluginsIfNeeded() {
        guard !didLoadDynamicPlugins, let dynamicPluginManager else {
            return
        }

        dynamicPlugins = dynamicPluginManager.loadInstalledPlugins()
        didLoadDynamicPlugins = true
        configureCallbacks(for: dynamicPlugins)
        syncPluginManagementState()
        refreshAll()
    }

    var hasInstalledDynamicPlugins: Bool {
        guard let dynamicPluginManager else {
            return false
        }

        return !dynamicPluginManager.installedPackageVersionsByID().isEmpty
    }

    @discardableResult
    func automaticUpdateInstalledPluginsBeforeLoading() async -> Bool {
        guard let pluginCatalogManager else {
            loadDynamicPluginsIfNeeded()
            return true
        }

        automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
            phase: .checking,
            pluginIDs: [],
            message: nil
        )

        await pluginCatalogManager.refreshCatalog()
        syncPluginManagementState()

        if let errorMessage = pluginCatalogManager.status.errorMessage {
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .failed,
                pluginIDs: [],
                message: errorMessage
            )
            loadDynamicPluginsIfNeeded()
            return false
        }

        let updatePlan = pluginCatalogManager.automaticUpdatePlanForInstalledPlugins()
        guard !updatePlan.isEmpty else {
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .completed,
                pluginIDs: [],
                message: AppL10n.plugins("plugin.autoUpdate.message.noInstalledUpdates", defaultValue: "已安装插件都是最新版本。")
            )
            loadDynamicPluginsIfNeeded()
            return true
        }

        presentPluginMarketplace()
        automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
            phase: .updating,
            pluginIDs: updatePlan.updateableInstalledPluginIDs,
            message: AppL10n.pluginsFormat(
                "plugin.autoUpdate.message.progressFormat",
                defaultValue: "已完成 %d/%d",
                0,
                updatePlan.updateableInstalledPluginIDs.count
            )
        )
        syncPluginManagementState()

        do {
            try await pluginCatalogManager.updateInstalledPluginsToLatestBeforeLoading { [weak self] progress in
                self?.automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                    phase: .updating,
                    pluginIDs: updatePlan.updateableInstalledPluginIDs,
                    message: AppL10n.pluginsFormat(
                        "plugin.autoUpdate.message.progressFormat",
                        defaultValue: "已完成 %d/%d",
                        progress.completedCount,
                        progress.totalCount
                    )
                )
            }
            syncPluginManagementState()
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .completed,
                pluginIDs: updatePlan.updateableInstalledPluginIDs,
                message: AppL10n.pluginsFormat(
                    "plugin.autoUpdate.message.updatedInstalledFormat",
                    defaultValue: "已更新 %d 个插件。",
                    updatePlan.updateableInstalledPluginIDs.count
                )
            )
        } catch {
            syncPluginManagementState()
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .failed,
                pluginIDs: updatePlan.updateableInstalledPluginIDs,
                message: error.localizedDescription
            )
        }

        loadDynamicPluginsIfNeeded()
        return automaticPluginUpdateStatus.phase == .completed
    }

    func installPluginFromCatalog(pluginID: String) async throws {
        guard let pluginCatalogManager else {
            return
        }

        try await pluginCatalogManager.installPlugin(id: pluginID)
        syncPluginManagementState()
    }

    func updatePluginFromCatalog(pluginID: String) async throws {
        guard let pluginCatalogManager else {
            return
        }

        try await pluginCatalogManager.updatePlugin(id: pluginID)
        syncPluginManagementState()
    }

    func updateAvailablePluginsFromCatalog(
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        guard let pluginCatalogManager else {
            return
        }

        defer {
            syncPluginManagementState()
        }

        try await pluginCatalogManager.updateAvailablePlugins(progress: progress)
    }

    func installPluginPackage(from sourceURL: URL) throws {
        try dynamicPluginManager?.installPluginPackage(from: sourceURL)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    func updatePluginPackage(from sourceURL: URL) throws {
        try dynamicPluginManager?.updatePluginPackage(from: sourceURL)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    func uninstallDynamicPlugin(pluginID: String, removeData: Bool = false) throws {
        try dynamicPluginManager?.uninstallPlugin(pluginID: pluginID, removeData: removeData)
        pluginDisplayPreferencesStore.removePlugin(pluginID)
        shortcutStore.removeCustomizations(forPluginID: pluginID)
        shortcutErrors = shortcutErrors.filter { !$0.key.hasPrefix("\(pluginID).shortcut.") }
        isolatedPluginFailures.removeValue(forKey: pluginID)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    private var plugins: [any MacToolsPlugin] {
        builtInPlugins + dynamicPlugins
    }

    private var activePlugins: [any MacToolsPlugin] {
        plugins.filter { isolatedPluginFailures[$0.metadata.id] == nil }
    }

    private func portablePluginPreferences() -> [String: Data] {
        activePlugins.reduce(into: [String: Data]()) { result, plugin in
            guard let portablePreferences = plugin as? any PluginPortablePreferencesProviding,
                  let data = guardedOptionalValue(
                    for: plugin,
                    operation: "export portable preferences",
                    portablePreferences.makePortablePreferencesBackup()
                  )
            else {
                return
            }
            result[plugin.metadata.id] = data
        }
    }

    private func restorePortablePluginPreferences(_ pluginPreferences: [String: Data]) {
        for (pluginID, data) in pluginPreferences {
            guard let plugin = corePlugin(for: pluginID),
                  let portablePreferences = plugin as? any PluginPortablePreferencesProviding
            else {
                continue
            }

            guardPluginCall(plugin, operation: "restore portable preferences") {
                portablePreferences.restorePortablePreferences(from: data)
            }
        }
    }

    private func corePlugin(for pluginID: String) -> (any MacToolsPlugin)? {
        activePlugins.first(where: { $0.metadata.id == pluginID })
    }

    private func configureCallbacks(for plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            let pluginID = plugin.metadata.id

            plugin.onStateChange = { [weak self] in
                self?.rebuildDerivedStateAfterPluginChange(pluginID: pluginID)
            }
            plugin.requestPermissionGuidance = { [weak self] permissionID in
                self?.requestPermissionGuidance(forPluginID: pluginID, permissionID: permissionID)
            }
            plugin.shortcutBindingResolver = { [weak self] shortcutDefinitionID in
                self?.resolvedBinding(forPluginID: pluginID, shortcutDefinitionID: shortcutDefinitionID)
            }
            if let anchorable = plugin as? any DropZoneAnchorProviding {
                anchorable.anchorRectProvider = { [weak self] in
                    self?.statusItemButtonFrameProvider?()
                }
            }
            if let configurationPresenting = plugin as? any PluginConfigurationPresenting {
                configurationPresenting.requestConfigurationPresentation = { [weak self] in
                    self?.presentPluginConfiguration(pluginID: pluginID)
                }
            }
            if let activityStateHandling = plugin as? any PluginApplicationActivityStateHandling {
                guardPluginCall(plugin, operation: "set application activity state") {
                    activityStateHandling.applicationActivityStateDidChange(applicationActivityState)
                }
            }
            configureHostStatusItemCallbacks(for: [plugin])
        }
    }

    private func handleApplicationActivityStateChange(
        _ state: PluginApplicationActivityState
    ) {
        guard applicationActivityState != state else { return }
        applicationActivityState = state

        for plugin in activePlugins {
            guard let activityStateHandling = plugin as? any PluginApplicationActivityStateHandling else {
                continue
            }
            guardPluginCall(plugin, operation: "update application activity state") {
                activityStateHandling.applicationActivityStateDidChange(state)
            }
        }
    }

    private func configureHostStatusItemCallbacks(for plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            guard let recoverable = plugin as? any MenuBarHostStatusItemRecovering else { continue }
            recoverable.hostStatusItemFrameProvider = { [weak self] in
                self?.statusItemButtonFrameProvider?()
            }
            recoverable.resetHostStatusItemPosition = { [weak self] in
                self?.resetStatusItemPosition?()
            }
        }
    }

    private func replaceDynamicPlugins(_ plugins: [any MacToolsPlugin]) {
        let previouslyVisibleSurfaces = visiblePanelSurfaces
        hideAllPanelSurfaces()
        visiblePanelSurfaces = previouslyVisibleSurfaces
        discardComponentViews()
        configurationViewCache.removeAll()
        loggedCapabilityMismatchPluginIDs.removeAll()
        dynamicResolvedCapabilitiesByID.removeAll()
        syncPluginManagementState()
        dynamicPlugins = plugins.sorted {
            if $0.metadata.order == $1.metadata.order {
                return $0.metadata.title.localizedCompare($1.metadata.title) == .orderedAscending
            }

            return $0.metadata.order < $1.metadata.order
        }
        configureCallbacks(for: dynamicPlugins)
        rebuildDerivedState()
        syncGlobalShortcuts()
    }

    private func syncPluginManagementState() {
        dynamicPluginCapabilitiesByID = dynamicPluginManager?.installedCapabilitiesByID() ?? [:]
        dynamicPluginCategoriesByID = dynamicPluginManager?.installedCategoriesByID() ?? [:]
        dynamicPluginReleaseChannelsByID = dynamicPluginManager?.installedReleaseChannelsByID() ?? [:]
        dynamicPluginManifestsByID = dynamicPluginManager?.installedManifestsByID() ?? [:]
        pluginManagementItems = dynamicPluginManager?.pluginManagementItems ?? []
        pluginCatalogStatus = pluginCatalogManager?.status ?? .unavailable
    }

    private func rebuildDerivedState(dirtyPluginIDs: Set<String>? = nil) {
        if dirtyPluginIDs == nil {
            cancelScheduledPluginStateRebuild()
        }

        let defaultDescriptors = defaultPluginDescriptors()
        pluginDisplayPreferencesStore.migrateLegacyHiddenPluginIDs(
            dashboardDefaultPluginIDs: defaultDescriptors
                .filter { $0.capabilities.supportedSurfaces.contains(.dashboard) }
                .map(\.metadata.id),
            featurePanelDefaultPluginIDs: defaultDescriptors
                .filter { $0.capabilities.supportedSurfaces.contains(.featurePanel) }
                .map(\.metadata.id)
        )

        let isolatedPluginCountAtStart = isolatedPluginFailures.count
        let orderedDescriptors = orderedPluginDescriptors()
        let descriptorIDs = Set(orderedDescriptors.map(\.metadata.id))
        var panelStatesByID = dirtyPluginIDs == nil ? [:] : cachedPanelStatesByID.filter {
            descriptorIDs.contains($0.key)
        }
        var primaryPanelIndicatorsByID = dirtyPluginIDs == nil
            ? [:]
            : cachedPrimaryPanelIndicatorsByID.filter { descriptorIDs.contains($0.key) }
        var evaluatedIndicatorPluginIDs = dirtyPluginIDs == nil
            ? Set<String>()
            : evaluatedPrimaryPanelIndicatorPluginIDs.intersection(descriptorIDs)
        var componentStatesByID = dirtyPluginIDs == nil ? [:] : cachedComponentStatesByID.filter {
            descriptorIDs.contains($0.key)
        }

        for descriptor in orderedDescriptors {
            let pluginID = descriptor.metadata.id
            let shouldReadPlugin = dirtyPluginIDs?.contains(pluginID) ?? true
            let plugin = descriptor.plugin

            if descriptor.hasPrimaryPanel,
               !isPluginIsolated(plugin),
               let primaryPanel = plugin.primaryPanel {
                if shouldReadPlugin || panelStatesByID[pluginID] == nil {
                    if let state = guardedValue(
                        for: plugin,
                        operation: "read primary panel state",
                        primaryPanel.primaryPanelState
                    ) {
                        panelStatesByID[pluginID] = state
                    } else {
                        panelStatesByID.removeValue(forKey: pluginID)
                    }
                }

                if let indicatorProvider = plugin as? any PluginPrimaryPanelIndicatorProviding {
                    if shouldReadPlugin || !evaluatedIndicatorPluginIDs.contains(pluginID) {
                        evaluatedIndicatorPluginIDs.insert(pluginID)
                        if let indicator = guardedOptionalValue(
                            for: plugin,
                            operation: "read primary panel indicator",
                            indicatorProvider.primaryPanelIndicator
                        ) {
                            primaryPanelIndicatorsByID[pluginID] = indicator
                        } else {
                            primaryPanelIndicatorsByID.removeValue(forKey: pluginID)
                        }
                    }
                } else {
                    evaluatedIndicatorPluginIDs.remove(pluginID)
                    primaryPanelIndicatorsByID.removeValue(forKey: pluginID)
                }
            } else {
                panelStatesByID.removeValue(forKey: pluginID)
                evaluatedIndicatorPluginIDs.remove(pluginID)
                primaryPanelIndicatorsByID.removeValue(forKey: pluginID)
            }

            if descriptor.hasComponentPanel,
               !isPluginIsolated(plugin),
               let componentPanel = plugin.componentPanel {
                if shouldReadPlugin || componentStatesByID[pluginID] == nil {
                    if let state = guardedValue(
                        for: plugin,
                        operation: "read component panel state",
                        componentPanel.componentPanelState
                    ) {
                        componentStatesByID[pluginID] = state
                    } else {
                        componentStatesByID.removeValue(forKey: pluginID)
                    }
                }
            } else {
                componentStatesByID.removeValue(forKey: pluginID)
            }
        }

        cachedPanelStatesByID = panelStatesByID
        cachedPrimaryPanelIndicatorsByID = primaryPanelIndicatorsByID
        evaluatedPrimaryPanelIndicatorPluginIDs = evaluatedIndicatorPluginIDs
        cachedComponentStatesByID = componentStatesByID
        self.primaryPanelIndicatorsByID = primaryPanelIndicatorsByID

        let featurePanelOrderedDescriptors = visiblePluginDescriptors(for: .featurePanel)
        let dashboardOrderedDescriptors = visiblePluginDescriptors(for: .dashboard)
        let featurePanelHiddenDescriptors = hiddenPluginDescriptors(for: .featurePanel)
        let dashboardHiddenDescriptors = hiddenPluginDescriptors(for: .dashboard)

        panelItems = featurePanelOrderedDescriptors.compactMap { descriptor in
            guard descriptor.hasPrimaryPanel else {
                return nil
            }

            let plugin = descriptor.plugin
            let metadata = descriptor.metadata
            guard
                let primaryPanel = plugin.primaryPanel,
                let state = panelStatesByID[metadata.id]
            else {
                return nil
            }

            guard state.isVisible else {
                return nil
            }

            let description = localizedDescription(
                state.errorMessage ?? state.subtitle,
                pluginMetadata: plugin.metadata,
                localizedMetadata: metadata
            )
            let descriptor = primaryPanel.primaryPanelDescriptor

            return PluginPanelItem(
                id: metadata.id,
                title: metadata.title,
                iconName: metadata.iconName,
                iconTint: metadata.iconTint,
                controlStyle: descriptor.controlStyle,
                menuActionBehavior: descriptor.menuActionBehavior,
                description: description.isEmpty ? metadata.defaultDescription : description,
                helpText: description.isEmpty ? metadata.defaultDescription : description,
                descriptionTone: state.errorMessage == nil ? .secondary : .error,
                isOn: state.isOn,
                isExpanded: state.isExpanded,
                isEnabled: state.isEnabled,
                detail: state.detail,
                buttonActionID: descriptor.controlStyle == .button ? "execute" : nil,
                buttonTitle: descriptor.buttonTitle
            )
        }

        componentItems = dashboardOrderedDescriptors.compactMap { descriptor in
            guard descriptor.hasComponentPanel else {
                return nil
            }

            let plugin = descriptor.plugin
            let metadata = descriptor.metadata
            guard
                let componentPanel = plugin.componentPanel,
                let state = componentStatesByID[metadata.id]
            else {
                return nil
            }

            guard state.isVisible else {
                return nil
            }

            let description = localizedDescription(
                state.errorMessage ?? state.subtitle,
                pluginMetadata: plugin.metadata,
                localizedMetadata: metadata
            )

            return PluginComponentItem(
                id: metadata.id,
                title: metadata.title,
                iconName: metadata.iconName,
                iconTint: metadata.iconTint,
                description: description.isEmpty ? metadata.defaultDescription : description,
                helpText: description.isEmpty ? metadata.defaultDescription : description,
                descriptionTone: state.errorMessage == nil ? .secondary : .error,
                span: componentPanel.descriptor.span,
                isActive: state.isActive,
                isEnabled: state.isEnabled
            )
        }
        trimComponentViewCache(keeping: Set(componentItems.map(\.id)))
        syncVisiblePanelSurfaces()

        featureManagementItems = orderedDescriptors.compactMap { descriptor in
            let metadata = descriptor.metadata
            guard !descriptor.capabilities.supportedSurfaces.isEmpty else {
                return nil
            }
            return PluginFeatureManagementItem(
                id: metadata.id,
                title: metadata.title,
                description: metadata.defaultDescription,
                iconName: metadata.iconName,
                iconTint: metadata.iconTint,
                isVisible: true,
                isActive: (
                    panelStatesByID[metadata.id]?.isOn == true
                        || componentStatesByID[metadata.id]?.isActive == true
                ),
                presentation: presentation(for: descriptor),
                category: dynamicPluginCategoriesByID[metadata.id] ?? nil,
                releaseChannel: dynamicPluginReleaseChannelsByID[metadata.id] ?? nil
            )
        }

        dashboardLayoutItems = dashboardOrderedDescriptors.map { descriptor in
            surfaceLayoutItem(
                for: descriptor,
                surface: .dashboard,
                isVisible: true,
                panelStatesByID: panelStatesByID,
                componentStatesByID: componentStatesByID
            )
        }
        dashboardHiddenLayoutItems = dashboardHiddenDescriptors.map { descriptor in
            surfaceLayoutItem(
                for: descriptor,
                surface: .dashboard,
                isVisible: false,
                panelStatesByID: panelStatesByID,
                componentStatesByID: componentStatesByID
            )
        }
        featurePanelLayoutItems = featurePanelOrderedDescriptors.map { descriptor in
            surfaceLayoutItem(
                for: descriptor,
                surface: .featurePanel,
                isVisible: true,
                panelStatesByID: panelStatesByID,
                componentStatesByID: componentStatesByID
            )
        }
        featurePanelHiddenLayoutItems = featurePanelHiddenDescriptors.map { descriptor in
            surfaceLayoutItem(
                for: descriptor,
                surface: .featurePanel,
                isVisible: false,
                panelStatesByID: panelStatesByID,
                componentStatesByID: componentStatesByID
            )
        }

        settingsCards = orderedCorePlugins().flatMap { plugin in
            let sections = guardedValue(
                for: plugin,
                operation: "read settings sections",
                plugin.settingsSections
            ) ?? []

            return sections.map { section in
                PluginSettingsCard(
                    id: "\(plugin.metadata.id).\(section.id)",
                    pluginID: plugin.metadata.id,
                    title: section.title,
                    description: section.description,
                    statusText: section.status.text,
                    statusSystemImage: section.status.systemImage,
                    statusTone: section.status.tone,
                    footnote: section.footnote,
                    buttonTitle: section.buttonTitle,
                    actionID: section.actionID
                )
            }
        }

        permissionCards = orderedCorePlugins().flatMap { plugin -> [PluginPermissionCard] in
            let requirements = guardedValue(
                for: plugin,
                operation: "read permission requirements",
                plugin.permissionRequirements
            ) ?? []

            return requirements.compactMap { requirement -> PluginPermissionCard? in
                guard let state = guardedValue(
                    for: plugin,
                    operation: "read permission state",
                    plugin.permissionState(for: requirement.id)
                ) else {
                    return nil
                }

                return PluginPermissionCard(
                    id: "\(plugin.metadata.id).permission.\(requirement.id)",
                    pluginID: plugin.metadata.id,
                    permissionID: requirement.id,
                    title: requirement.title,
                    description: requirement.description,
                    iconSystemImage: permissionIconName(for: requirement.kind),
                    statusText: state.statusText ?? (state.isGranted
                        ? AppL10n.plugins("plugin.permission.granted", defaultValue: "已授权")
                        : AppL10n.plugins("plugin.permission.notGranted", defaultValue: "未授权")),
                    statusSystemImage: state.statusSystemImage ?? (state.isGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"),
                    statusTone: state.statusTone ?? (state.isGranted ? .positive : .caution),
                    footnote: state.footnote,
                    buttonTitle: permissionActionTitle(
                        for: requirement.kind,
                        isGranted: state.isGranted
                    )
                )
            }
        }

        shortcutItems = shortcutDescriptors().map { descriptor in
            let customization = shortcutStore.customization(for: descriptor.itemID)
            let binding = resolvedBinding(for: descriptor)

            return ShortcutSettingsItem(
                id: descriptor.itemID,
                pluginID: descriptor.pluginID,
                pluginTitle: descriptor.pluginTitle,
                title: descriptor.definition.title,
                description: descriptor.definition.description,
                bindingText: ShortcutFormatter.displayString(for: binding),
                isRequired: descriptor.definition.isRequired,
                canClear: !descriptor.definition.isRequired && binding != nil,
                usesDefaultValue: customization == .inheritDefault,
                errorMessage: shortcutErrors[descriptor.itemID],
                settingsGroupID: descriptor.definition.settingsGroupID,
                settingsGroupTitle: descriptor.definition.settingsGroupTitle,
                settingsGroupDescription: descriptor.definition.settingsGroupDescription,
                settingsControlTitle: descriptor.definition.settingsControlTitle,
                settingsControlSystemImage: descriptor.definition.settingsControlSystemImage
            )
        }

        let openSettingsBinding = resolvedOpenSettingsShortcutBinding
        openSettingsShortcut = AppShortcutSettingsItem(
            bindingText: ShortcutFormatter.displayString(for: openSettingsBinding),
            canClear: openSettingsBinding != nil,
            errorMessage: openSettingsShortcutError
        )

        pluginConfigurationItems = buildPluginConfigurationItems(
            settingsCards: settingsCards,
            permissionCards: permissionCards,
            shortcutItems: shortcutItems
        )
        if let dirtyPluginIDs {
            for pluginID in dirtyPluginIDs {
                configurationViewCache.removeValue(forKey: pluginID)
            }
        } else {
            configurationViewCache.removeAll()
        }
        trimConfigurationViewCache(keeping: Set(pluginConfigurationItems.map(\.id)))

        let newHasActivePlugin = panelStatesByID.contains { $0.value.isOn }
            || componentStatesByID.contains { $0.value.isActive }
        if hasActivePlugin != newHasActivePlugin {
            hasActivePlugin = newHasActivePlugin
        }

        if isolatedPluginFailures.count > isolatedPluginCountAtStart {
            rebuildDerivedState()
        }
    }

    private func handlePluginAction(rebuildAfterAction: Bool = true, _ action: () -> Void) {
        guard !isHandlingPluginAction else {
            action()
            return
        }

        isHandlingPluginAction = true

        action()

        isHandlingPluginAction = false
        if rebuildAfterAction {
            rebuildDerivedState()
        }
    }

    private func rebuildDerivedStateAfterPluginChange(pluginID: String) {
        guard !isHandlingPluginAction else {
            return
        }

        dirtyPluginIDs.insert(pluginID)
        schedulePluginStateChangeRebuild()
    }

    private func schedulePluginStateChangeRebuild() {
        guard pluginStateChangeRebuildTask == nil else {
            return
        }

        pluginStateChangeRebuildTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: pluginStateChangeRebuildDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            let pluginIDs = dirtyPluginIDs
            dirtyPluginIDs.removeAll()
            pluginStateChangeRebuildTask = nil
            guard !pluginIDs.isEmpty else {
                return
            }

            rebuildDerivedState(dirtyPluginIDs: pluginIDs)
        }
    }

    private func cancelScheduledPluginStateRebuild() {
        pluginStateChangeRebuildTask?.cancel()
        pluginStateChangeRebuildTask = nil
        dirtyPluginIDs.removeAll()
    }

    private func guardedValue<T>(
        for plugin: any MacToolsPlugin,
        operation: String,
        _ value: @autoclosure () -> T
    ) -> T? {
        guard !isPluginIsolated(plugin) else {
            return nil
        }

        switch PluginInvocationGuard.value(operation: operation, value) {
        case let .success(value):
            return value
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
            return nil
        }
    }

    private func guardedOptionalValue<T>(
        for plugin: any MacToolsPlugin,
        operation: String,
        _ value: @autoclosure () -> T?
    ) -> T? {
        guard !isPluginIsolated(plugin) else {
            return nil
        }

        switch PluginInvocationGuard.value(operation: operation, value) {
        case let .success(value):
            return value
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
            return nil
        }
    }

    private func guardPluginCall(
        _ plugin: any MacToolsPlugin,
        operation: String,
        _ action: () -> Void
    ) {
        guard !isPluginIsolated(plugin) else {
            return
        }

        switch PluginInvocationGuard.run(operation: operation, action) {
        case .success:
            break
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
        }
    }

    private func guardedConfigurationView(
        for plugin: any MacToolsPlugin,
        configuration: PluginConfiguration,
        context: PluginConfigurationContext
    ) -> AnyView {
        guardedValue(
            for: plugin,
            operation: "make configuration view",
            configuration.makeView(context)
        ) ?? AnyView(EmptyView())
    }

    private func isPluginIsolated(_ plugin: any MacToolsPlugin) -> Bool {
        isolatedPluginFailures[plugin.metadata.id] != nil
    }

    private func isolatePlugin(
        _ plugin: any MacToolsPlugin,
        operation: String,
        failure: PluginInvocationFailure
    ) {
        let pluginID = plugin.metadata.id
        let message = failure.localizedDescription

        guard isolatedPluginFailures[pluginID] == nil else {
            return
        }

        isolatedPluginFailures[pluginID] = message
        removePluginFromVisiblePanelSurfaces(pluginID, notify: false)
        cachedPanelStatesByID.removeValue(forKey: pluginID)
        cachedComponentStatesByID.removeValue(forKey: pluginID)
        componentViewCache.removeValue(forKey: pluginID)
        configurationViewCache.removeValue(forKey: pluginID)
        shortcutErrors = shortcutErrors.filter { !$0.key.hasPrefix("\(pluginID).shortcut.") }

        AppLog.pluginHost.error(
            "Plugin \(pluginID, privacy: .public) isolated after \(operation, privacy: .public): \(message, privacy: .public)"
        )

        switch PluginInvocationGuard.run(operation: "deactivate isolated plugin \(pluginID)", {
            plugin.deactivate(reason: .disabled)
        }) {
        case .success:
            break
        case let .failure(deactivateFailure):
            AppLog.pluginHost.error(
                "Plugin \(pluginID, privacy: .public) failed during isolation deactivate: \(deactivateFailure.localizedDescription, privacy: .public)"
            )
        }

        plugin.onStateChange = nil
        plugin.requestPermissionGuidance = nil
        plugin.shortcutBindingResolver = nil
        (plugin as? any PluginConfigurationPresenting)?.requestConfigurationPresentation = nil
        syncGlobalShortcuts()
    }

    private func scheduleDisplayTopologyRefresh() {
        displayTopologyRefreshTask?.cancel()
        let refreshDelay = displayTopologyRefreshDelay
        displayTopologyRefreshTask = Task { @MainActor [weak self, refreshDelay] in
            do {
                try await Task.sleep(for: refreshDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.refreshDisplayTopologyNow()
        }
    }

    private func refreshDisplayTopologyNow() {
        displayTopologyRefreshTask = nil
        handlePluginAction {
            for plugin in activePlugins {
                if let displayTopologyRefreshing = plugin as? DisplayTopologyRefreshing {
                    guardPluginCall(plugin, operation: "refresh display topology") {
                        displayTopologyRefreshing.refreshDisplayTopology()
                    }
                }
            }
        }
    }

    private func refreshAccessibilityPermissionNow() {
        handlePluginAction {
            for plugin in activePlugins {
                if let accessibilityRefreshing = plugin as? AccessibilityPermissionRefreshing {
                    guardPluginCall(plugin, operation: "refresh accessibility permission") {
                        accessibilityRefreshing.refreshAccessibilityPermission()
                    }
                }
            }
        }
    }

    private func buildPluginConfigurationItems(
        settingsCards: [PluginSettingsCard],
        permissionCards: [PluginPermissionCard],
        shortcutItems: [ShortcutSettingsItem]
    ) -> [PluginConfigurationItem] {
        orderedPluginDescriptors().compactMap { descriptor in
            let pluginID = descriptor.metadata.id
            let matchingSettingsCards = settingsCards.filter { $0.pluginID == pluginID }
            let matchingPermissionCards = permissionCards.filter { $0.pluginID == pluginID }
            let allMatchingShortcutItems = shortcutItems.filter { $0.pluginID == pluginID }
            let configurations: [PluginConfiguration]
            if descriptor.hasConfiguration,
               let configuration = guardedOptionalValue(
                    for: descriptor.plugin,
                    operation: "read plugin configuration",
                    descriptor.plugin.configuration
               ) {
                configurations = [configuration]
            } else {
                configurations = []
            }
            let integratedShortcutGroupIDs = Set(
                configurations.flatMap(\.integratedShortcutGroupIDs)
            )
            let matchingShortcutItems = allMatchingShortcutItems.filter { item in
                guard let groupID = item.settingsGroupID else { return true }
                return !integratedShortcutGroupIDs.contains(groupID)
            }
            let hasConfigurationSurface = !matchingSettingsCards.isEmpty
                || !matchingPermissionCards.isEmpty
                || !matchingShortcutItems.isEmpty
                || !configurations.isEmpty

            guard hasConfigurationSurface else {
                return nil
            }

            return PluginConfigurationItem(
                id: pluginID,
                pluginID: pluginID,
                title: descriptor.metadata.title,
                description: configurations.first?.description ?? descriptor.metadata.defaultDescription,
                iconName: descriptor.metadata.iconName,
                iconTint: descriptor.metadata.iconTint,
                settingsCards: matchingSettingsCards,
                permissionCards: matchingPermissionCards,
                shortcutItems: matchingShortcutItems,
                hasCustomConfiguration: !configurations.isEmpty,
                prefersFullHeight: configurations.first?.prefersFullHeight ?? false
            )
        }
    }

    private func surfaceLayoutItem(
        for descriptor: PluginDescriptor,
        surface: PluginDisplaySurface,
        isVisible: Bool,
        panelStatesByID: [String: PluginPanelState],
        componentStatesByID: [String: PluginComponentState]
    ) -> PluginSurfaceLayoutItem {
        let metadata = descriptor.metadata
        let isActive: Bool
        switch surface {
        case .dashboard:
            isActive = componentStatesByID[metadata.id]?.isActive == true
        case .featurePanel:
            isActive = panelStatesByID[metadata.id]?.isOn == true
        }
        return PluginSurfaceLayoutItem(
            id: metadata.id,
            title: metadata.title,
            description: metadata.defaultDescription,
            iconName: metadata.iconName,
            iconTint: metadata.iconTint,
            capabilities: descriptor.capabilities,
            isVisible: isVisible,
            isActive: isActive,
            canUninstall: dynamicPluginManifestsByID[metadata.id] != nil,
            category: dynamicPluginCategoriesByID[metadata.id] ?? nil,
            releaseChannel: dynamicPluginReleaseChannelsByID[metadata.id] ?? nil
        )
    }

    private func shortcutDescriptors() -> [ShortcutDescriptor] {
        orderedCorePlugins().flatMap { plugin in
            let definitions = guardedValue(
                for: plugin,
                operation: "read shortcut definitions",
                plugin.shortcutDefinitions
            ) ?? []

            return definitions.map { definition in
                ShortcutDescriptor(
                    itemID: shortcutItemID(
                        pluginID: plugin.metadata.id,
                        shortcutDefinitionID: definition.id
                    ),
                    pluginID: plugin.metadata.id,
                    pluginTitle: plugin.metadata.title,
                    definition: definition,
                    plugin: plugin
                )
            }
        }
    }

    private var defaultPluginIDs: [String] {
        defaultPluginDescriptors().map(\.metadata.id)
    }

    private func defaultPluginIDs(for surface: PluginDisplaySurface) -> [String] {
        defaultPluginDescriptors()
            .filter { $0.capabilities.supportedSurfaces.contains(surface) }
            .map(\.metadata.id)
    }

    private func orderedPluginIDs() -> [String] {
        pluginDisplayPreferencesStore.orderedPluginIDs(defaultPluginIDs: defaultPluginIDs)
    }

    private func orderedPlugins() -> [any MacToolsPlugin] {
        let pluginsByID = pluginsByID()

        return orderedPluginIDs().compactMap { pluginsByID[$0] }
    }

    private func orderedCorePlugins() -> [any MacToolsPlugin] {
        orderedPluginDescriptors().map(\.plugin)
    }

    private func orderedPluginDescriptors() -> [PluginDescriptor] {
        let descriptorsByID = descriptorsByID()

        return orderedPluginIDs().compactMap { descriptorsByID[$0] }
    }

    private func visiblePluginDescriptors(for surface: PluginDisplaySurface) -> [PluginDescriptor] {
        let descriptorsByID = descriptorsByID()
        return visiblePluginIDs(for: surface).compactMap { descriptorsByID[$0] }
    }

    private func hiddenPluginDescriptors(for surface: PluginDisplaySurface) -> [PluginDescriptor] {
        let descriptorsByID = descriptorsByID()
        return hiddenPluginIDs(for: surface).compactMap { descriptorsByID[$0] }
    }

    private func visiblePluginIDs(for surface: PluginDisplaySurface) -> [String] {
        pluginDisplayPreferencesStore.visiblePluginIDs(
            for: surface,
            defaultPluginIDs: defaultPluginIDs(for: surface)
        )
    }

    private func hiddenPluginIDs(for surface: PluginDisplaySurface) -> [String] {
        pluginDisplayPreferencesStore.hiddenPluginIDs(
            for: surface,
            defaultPluginIDs: defaultPluginIDs(for: surface)
        )
    }

    private func pluginsByID() -> [String: any MacToolsPlugin] {
        activePlugins.reduce(into: [String: any MacToolsPlugin]()) { result, plugin in
            let id = plugin.metadata.id

            if result[id] == nil {
                result[id] = plugin
            }
        }
    }

    private func descriptorsByID() -> [String: PluginDescriptor] {
        defaultPluginDescriptors().reduce(into: [String: PluginDescriptor]()) { result, descriptor in
            let id = descriptor.metadata.id

            if result[id] == nil {
                result[id] = descriptor
            }
        }
    }

    private func defaultPluginDescriptors() -> [PluginDescriptor] {
        let descriptors = builtInPlugins
            .map {
                PluginDescriptor(
                    metadata: $0.metadata,
                    plugin: $0,
                    capabilities: builtInCapabilities(for: $0)
                )
            }
            + dynamicPlugins.map {
                PluginDescriptor(
                    metadata: localizedMetadata(for: $0.metadata),
                    plugin: $0,
                    capabilities: dynamicCapabilities(for: $0)
                )
            }

        return descriptors
            .filter { !isPluginIsolated($0.plugin) }
            .sorted { lhs, rhs in
                if lhs.metadata.order == rhs.metadata.order {
                    return lhs.metadata.title.localizedCompare(rhs.metadata.title) == .orderedAscending
                }

                return lhs.metadata.order < rhs.metadata.order
            }
    }

    private func localizedMetadata(for metadata: PluginMetadata) -> PluginMetadata {
        guard let localized = PluginLocalizationMatcher.localizedMetadata(
            from: dynamicPluginManifestsByID[metadata.id]?.localizedMetadata ?? [:]
        )
        else {
            return metadata
        }

        return PluginMetadata(
            id: metadata.id,
            title: localized.displayName ?? metadata.title,
            iconName: metadata.iconName,
            iconTint: metadata.iconTint,
            order: metadata.order,
            defaultDescription: localized.summary ?? metadata.defaultDescription
        )
    }

    private func localizedDescription(
        _ description: String,
        pluginMetadata: PluginMetadata,
        localizedMetadata: PluginMetadata
    ) -> String {
        // Replace only the metadata default; panel-specific descriptions and
        // errors must remain intact even if their text happens to be localized.
        description == pluginMetadata.defaultDescription
            ? localizedMetadata.defaultDescription
            : description
    }

    private func builtInCapabilities(for plugin: any MacToolsPlugin) -> PluginHostCapabilities {
        if let cachedCapabilities = builtInCapabilitiesByID[plugin.metadata.id] {
            return cachedCapabilities
        }

        let capabilities = PluginHostCapabilities(
            supportsDashboard: plugin.componentPanel != nil,
            supportsFeaturePanel: plugin.primaryPanel != nil,
            hasCustomConfiguration: plugin.configuration != nil
        )
        builtInCapabilitiesByID[plugin.metadata.id] = capabilities
        return capabilities
    }

    private func dynamicCapabilities(for plugin: any MacToolsPlugin) -> PluginHostCapabilities {
        if let cachedCapabilities = dynamicResolvedCapabilitiesByID[plugin.metadata.id] {
            return cachedCapabilities
        }

        guard let declared = dynamicPluginCapabilitiesByID[plugin.metadata.id] else {
            let capabilities = PluginHostCapabilities(
                supportsDashboard: plugin.componentPanel != nil,
                supportsFeaturePanel: plugin.primaryPanel != nil,
                hasCustomConfiguration: plugin.configuration != nil
            )
            dynamicResolvedCapabilitiesByID[plugin.metadata.id] = capabilities
            return capabilities
        }

        let runtimeSupportsFeaturePanel = plugin.primaryPanel != nil
        let runtimeSupportsDashboard = plugin.componentPanel != nil
        let hasPanelMismatch = declared.primaryPanel != runtimeSupportsFeaturePanel
            || declared.componentPanel != runtimeSupportsDashboard

        if hasPanelMismatch,
           loggedCapabilityMismatchPluginIDs.insert(plugin.metadata.id).inserted {
            AppLog.pluginHost.warning(
                "Plugin \(plugin.metadata.id, privacy: .public) panel capability mismatch; declared primary=\(declared.primaryPanel, privacy: .public), component=\(declared.componentPanel, privacy: .public), runtime primary=\(runtimeSupportsFeaturePanel, privacy: .public), component=\(runtimeSupportsDashboard, privacy: .public)"
            )
        }

        let capabilities = PluginHostCapabilities(
            supportsDashboard: declared.componentPanel && runtimeSupportsDashboard,
            supportsFeaturePanel: declared.primaryPanel && runtimeSupportsFeaturePanel,
            hasCustomConfiguration: declared.configuration
        )
        dynamicResolvedCapabilitiesByID[plugin.metadata.id] = capabilities
        return capabilities
    }

    private func presentation(for descriptor: PluginDescriptor) -> PluginFeaturePresentation {
        switch (
            descriptor.capabilities.supportsFeaturePanel,
            descriptor.capabilities.supportsDashboard
        ) {
        case (true, true):
            return .featureAndComponentPanel
        case (true, false):
            return .featurePanel
        case (false, true):
            return .componentPanel
        case (false, false):
            assertionFailure("Settings-only plugins do not have a panel presentation")
            return .featurePanel
        }
    }

    private func trimComponentViewCache(keeping visibleComponentIDs: Set<String>) {
        componentViewCache = componentViewCache.filter { visibleComponentIDs.contains($0.key) }
    }

    private func pluginIDs(for surface: PluginPanelSurface) -> Set<String> {
        switch surface {
        case .component:
            return Set(componentItems.map(\.id))
        case .primary:
            return Set(panelItems.map(\.id))
        }
    }

    private func syncVisiblePanelSurfaces() {
        for surface in visiblePanelSurfaces {
            updateVisiblePanelSurface(
                surface,
                visiblePluginIDs: pluginIDs(for: surface)
            )
        }
    }

    private func hideAllPanelSurfaces() {
        for surface in PluginPanelSurface.allCases {
            updateVisiblePanelSurface(surface, visiblePluginIDs: [])
        }
        visiblePanelSurfaces.removeAll()
    }

    private func updateVisiblePanelSurface(
        _ surface: PluginPanelSurface,
        visiblePluginIDs nextVisiblePluginIDs: Set<String>
    ) {
        let previousVisiblePluginIDs = visiblePanelSurfacePluginIDs[surface] ?? []
        let hiddenPluginIDs = previousVisiblePluginIDs.subtracting(nextVisiblePluginIDs)
        let shownPluginIDs = nextVisiblePluginIDs.subtracting(previousVisiblePluginIDs)

        guard !hiddenPluginIDs.isEmpty || !shownPluginIDs.isEmpty else {
            return
        }

        for pluginID in hiddenPluginIDs {
            notifyPanelSurfaceHidden(surface, pluginID: pluginID)
        }

        for pluginID in shownPluginIDs {
            notifyPanelSurfaceVisible(surface, pluginID: pluginID)
        }

        let visiblePluginIDs = nextVisiblePluginIDs.filter { pluginID in
            guard let plugin = corePlugin(for: pluginID) else {
                return false
            }

            return !isPluginIsolated(plugin)
        }

        if visiblePluginIDs.isEmpty {
            visiblePanelSurfacePluginIDs.removeValue(forKey: surface)
        } else {
            visiblePanelSurfacePluginIDs[surface] = visiblePluginIDs
        }
    }

    private func notifyPanelSurfaceVisible(_ surface: PluginPanelSurface, pluginID: String) {
        guard
            let plugin = corePlugin(for: pluginID),
            let lifecycleHandler = plugin as? any PluginPanelSurfaceLifecycleHandling
        else {
            return
        }

        guardPluginCall(plugin, operation: "show \(surface) panel surface") {
            lifecycleHandler.panelSurfaceDidBecomeVisible(surface)
        }
    }

    private func notifyPanelSurfaceHidden(_ surface: PluginPanelSurface, pluginID: String) {
        guard
            let plugin = corePlugin(for: pluginID),
            let lifecycleHandler = plugin as? any PluginPanelSurfaceLifecycleHandling
        else {
            return
        }

        guardPluginCall(plugin, operation: "hide \(surface) panel surface") {
            lifecycleHandler.panelSurfaceDidBecomeHidden(surface)
        }
    }

    private func removePluginFromVisiblePanelSurfaces(_ pluginID: String, notify: Bool) {
        for surface in PluginPanelSurface.allCases {
            guard var pluginIDs = visiblePanelSurfacePluginIDs[surface] else {
                continue
            }

            guard pluginIDs.remove(pluginID) != nil else {
                continue
            }

            if notify {
                notifyPanelSurfaceHidden(surface, pluginID: pluginID)
            }

            if pluginIDs.isEmpty {
                visiblePanelSurfacePluginIDs.removeValue(forKey: surface)
            } else {
                visiblePanelSurfacePluginIDs[surface] = pluginIDs
            }
        }
    }

    private func trimConfigurationViewCache(keeping configurationPluginIDs: Set<String>) {
        configurationViewCache = configurationViewCache.filter {
            configurationPluginIDs.contains($0.key)
        }
    }

    private func isAvailable(
        _ landingPage: PluginSettingsLandingPage,
        dashboardIsAvailable: Bool,
        featurePanelIsAvailable: Bool
    ) -> Bool {
        switch landingPage {
        case .dashboard:
            dashboardIsAvailable
        case .featurePanel:
            featurePanelIsAvailable
        case .marketplace:
            true
        }
    }

    private func shortcutDescriptor(for shortcutID: String) -> ShortcutDescriptor? {
        shortcutDescriptors().first(where: { $0.itemID == shortcutID })
    }

    private func shortcutItemID(pluginID: String, shortcutDefinitionID: String) -> String {
        "\(pluginID).shortcut.\(shortcutDefinitionID)"
    }

    private func resolvedBinding(for descriptor: ShortcutDescriptor) -> ShortcutBinding? {
        shortcutStore.resolvedBinding(
            for: descriptor.itemID,
            default: descriptor.definition.defaultBinding
        )
    }

    private var resolvedOpenSettingsShortcutBinding: ShortcutBinding? {
        shortcutStore.resolvedBinding(for: AppShortcut.openSettingsID, default: nil)
    }

    private func resolvedBinding(forPluginID pluginID: String, shortcutDefinitionID: String) -> ShortcutBinding? {
        guard let descriptor = shortcutDescriptors().first(where: {
            $0.pluginID == pluginID && $0.definition.id == shortcutDefinitionID
        }) else {
            return nil
        }

        return resolvedBinding(for: descriptor)
    }

    private func applyImportedShortcutCustomizations(
        _ importedCustomizations: [String: ShortcutCustomization]
    ) -> [String: String] {
        let descriptors = shortcutDescriptors()
        let openSettingsCustomization = importedCustomizations[AppShortcut.openSettingsID] ?? .inheritDefault
        let targetCustomizations = Dictionary(
            descriptors.map { descriptor in
                (descriptor.itemID, importedCustomizations[descriptor.itemID] ?? .inheritDefault)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let errors = validateImportedShortcutCustomizations(
            targetCustomizations,
            descriptors: descriptors,
            openSettingsCustomization: openSettingsCustomization
        )

        guard errors.isEmpty else {
            return importShortcutErrorMessages(errors, descriptors: descriptors)
        }

        for descriptor in descriptors {
            guard let customization = targetCustomizations[descriptor.itemID] else {
                continue
            }

            shortcutStore.setCustomization(customization, for: descriptor.itemID)
            shortcutErrors.removeValue(forKey: descriptor.itemID)
            notifyShortcutBindingChange(
                for: descriptor,
                binding: ShortcutStore.resolve(
                    customization: customization,
                    defaultBinding: descriptor.definition.defaultBinding
                )
            )
        }
        shortcutStore.setCustomization(openSettingsCustomization, for: AppShortcut.openSettingsID)
        openSettingsShortcutError = nil

        return [:]
    }

    private func importShortcutErrorMessages(
        _ errors: [String: String],
        descriptors: [ShortcutDescriptor]
    ) -> [String: String] {
        let descriptorsByID = Dictionary(
            descriptors.map { ($0.itemID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return Dictionary(
            errors.map { shortcutID, message in
                let title = shortcutID == AppShortcut.openSettingsID
                    ? AppL10n.plugins("plugin.permission.openSettings", defaultValue: "打开设置")
                    : descriptorsByID[shortcutID].map {
                    "\($0.pluginTitle) · \($0.definition.title)"
                } ?? shortcutID
                return (shortcutID, "\(title): \(message)")
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func validateImportedShortcutCustomizations(
        _ customizations: [String: ShortcutCustomization],
        descriptors: [ShortcutDescriptor],
        openSettingsCustomization: ShortcutCustomization
    ) -> [String: String] {
        var bindingsByID: [String: ShortcutBinding?] = [:]
        var errors: [String: String] = [:]

        let openSettingsBinding = ShortcutStore.resolve(
            customization: openSettingsCustomization,
            defaultBinding: nil
        )

        if let openSettingsBinding {
            if !openSettingsBinding.hasRequiredModifiers {
                errors[AppShortcut.openSettingsID] = ShortcutValidationError.missingModifier.localizedDescription
            } else if ShortcutKeyCode.isModifier(openSettingsBinding.keyCode) {
                errors[AppShortcut.openSettingsID] = ShortcutValidationError.modifierOnly.localizedDescription
            }
        }

        for descriptor in descriptors {
            let customization = customizations[descriptor.itemID] ?? .inheritDefault
            let binding = ShortcutStore.resolve(
                customization: customization,
                defaultBinding: descriptor.definition.defaultBinding
            )
            bindingsByID[descriptor.itemID] = binding

            do {
                if descriptor.definition.isRequired && binding == nil {
                    throw ShortcutValidationError.requiredShortcut
                }

                if let binding {
                    guard binding.hasRequiredModifiers else {
                        throw ShortcutValidationError.missingModifier
                    }

                    guard !ShortcutKeyCode.isModifier(binding.keyCode) else {
                        throw ShortcutValidationError.modifierOnly
                    }
                }
            } catch {
                errors[descriptor.itemID] = error.localizedDescription
            }
        }

        for (index, descriptor) in descriptors.enumerated() {
            guard let binding = bindingsByID[descriptor.itemID] ?? nil else {
                continue
            }

            for otherDescriptor in descriptors.dropFirst(index + 1) {
                guard let otherBinding = bindingsByID[otherDescriptor.itemID] ?? nil,
                      otherBinding == binding,
                      !canShareShortcutBinding(descriptor, with: otherDescriptor)
                else {
                    continue
                }

                errors[descriptor.itemID] = ShortcutValidationError.duplicate(
                    ownerDescription: "\(otherDescriptor.pluginTitle) · \(otherDescriptor.definition.title)"
                ).localizedDescription
                errors[otherDescriptor.itemID] = ShortcutValidationError.duplicate(
                    ownerDescription: "\(descriptor.pluginTitle) · \(descriptor.definition.title)"
                ).localizedDescription
            }
        }

        if let openSettingsBinding {
            for descriptor in descriptors {
                guard let binding = bindingsByID[descriptor.itemID] ?? nil,
                      binding == openSettingsBinding
                else {
                    continue
                }

                errors[AppShortcut.openSettingsID] = ShortcutValidationError.duplicate(
                    ownerDescription: "\(descriptor.pluginTitle) · \(descriptor.definition.title)"
                ).localizedDescription
                errors[descriptor.itemID] = ShortcutValidationError.duplicate(
                    ownerDescription: AppL10n.plugins("plugin.permission.openSettings", defaultValue: "打开设置")
                ).localizedDescription
            }
        }

        return errors
    }

    @discardableResult
    private func applyShortcutCustomization(
        _ customization: ShortcutCustomization,
        for descriptor: ShortcutDescriptor
    ) -> String? {
        do {
            try validateShortcutCustomization(customization, for: descriptor)
            shortcutStore.setCustomization(customization, for: descriptor.itemID)
            notifyShortcutBindingChange(
                for: descriptor,
                binding: ShortcutStore.resolve(
                    customization: customization,
                    defaultBinding: descriptor.definition.defaultBinding
                )
            )
            shortcutErrors.removeValue(forKey: descriptor.itemID)
            rebuildDerivedState()
            syncGlobalShortcuts()
            return nil
        } catch let error as ShortcutValidationError {
            shortcutErrors[descriptor.itemID] = error.localizedDescription
            rebuildDerivedState()
            return error.localizedDescription
        } catch {
            shortcutErrors[descriptor.itemID] = error.localizedDescription
            rebuildDerivedState()
            return error.localizedDescription
        }
    }

    private func validateShortcutCustomization(
        _ customization: ShortcutCustomization,
        for descriptor: ShortcutDescriptor
    ) throws {
        let candidate = ShortcutStore.resolve(
            customization: customization,
            defaultBinding: descriptor.definition.defaultBinding
        )

        if descriptor.definition.isRequired && candidate == nil {
            throw ShortcutValidationError.requiredShortcut
        }

        if let candidate {
            guard candidate.hasRequiredModifiers else {
                throw ShortcutValidationError.missingModifier
            }

            guard !ShortcutKeyCode.isModifier(candidate.keyCode) else {
                throw ShortcutValidationError.modifierOnly
            }

            if let conflict = shortcutDescriptors().first(where: {
                $0.itemID != descriptor.itemID
                    && resolvedBinding(for: $0) == candidate
                    && !canShareShortcutBinding(descriptor, with: $0)
            }) {
                throw ShortcutValidationError.duplicate(
                    ownerDescription: "\(conflict.pluginTitle) · \(conflict.definition.title)"
                )
            }

            if candidate == resolvedOpenSettingsShortcutBinding {
                throw ShortcutValidationError.duplicate(
                    ownerDescription: AppL10n.plugins("plugin.permission.openSettings", defaultValue: "打开设置")
                )
            }
        }
    }

    private func validateOpenSettingsShortcut(_ binding: ShortcutBinding) throws {
        guard binding.hasRequiredModifiers else {
            throw ShortcutValidationError.missingModifier
        }

        guard !ShortcutKeyCode.isModifier(binding.keyCode) else {
            throw ShortcutValidationError.modifierOnly
        }

        if let conflict = shortcutDescriptors().first(where: {
            resolvedBinding(for: $0) == binding
        }) {
            throw ShortcutValidationError.duplicate(
                ownerDescription: "\(conflict.pluginTitle) · \(conflict.definition.title)"
            )
        }
    }

    private func canShareShortcutBinding(_ lhs: ShortcutDescriptor, with rhs: ShortcutDescriptor) -> Bool {
        guard let groupID = lhs.definition.sharedBindingGroupID else {
            return false
        }

        return groupID == rhs.definition.sharedBindingGroupID
    }

    private func notifyShortcutBindingChange(
        for descriptor: ShortcutDescriptor,
        binding: ShortcutBinding?
    ) {
        guard let handling = descriptor.plugin as? any PluginShortcutBindingChangeHandling else {
            return
        }

        guardPluginCall(descriptor.plugin, operation: "update shortcut binding") {
            handling.shortcutBindingDidChange(id: descriptor.definition.id, binding: binding)
        }
    }

    private func syncGlobalShortcuts() {
        var registrations = shortcutDescriptors().compactMap { descriptor -> GlobalShortcutManager.Registration? in
            guard descriptor.definition.scope == .global else {
                return nil
            }

            guard let binding = resolvedBinding(for: descriptor) else {
                return nil
            }

            return GlobalShortcutManager.Registration(
                shortcutID: descriptor.itemID,
                binding: binding
            )
        }

        if let openSettingsBinding = resolvedOpenSettingsShortcutBinding,
           !shortcutDescriptors().contains(where: { resolvedBinding(for: $0) == openSettingsBinding }) {
            registrations.append(
                GlobalShortcutManager.Registration(
                    shortcutID: AppShortcut.openSettingsID,
                    binding: openSettingsBinding
                )
            )
        }

        globalShortcutManager.updateBindings(registrations)
    }

    private func handleShortcutTrigger(shortcutID: String) {
        if shortcutID == AppShortcut.openSettingsID {
            settingsPresentationHandler?(.settings)
            return
        }

        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        handlePluginAction {
            guardPluginCall(descriptor.plugin, operation: "shortcut action") {
                if let eventHandler = descriptor.plugin as? any PluginShortcutEventHandling {
                    eventHandler.handleShortcutEvent(id: descriptor.definition.actionID, phase: .pressed)
                } else {
                    descriptor.plugin.handleShortcutAction(id: descriptor.definition.actionID)
                }
            }
        }
    }

    private func handleShortcutRelease(shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID),
              let eventHandler = descriptor.plugin as? any PluginShortcutEventHandling
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(descriptor.plugin, operation: "shortcut release") {
                eventHandler.handleShortcutEvent(id: descriptor.definition.actionID, phase: .released)
            }
        }
    }

    private func requestPermissionGuidance(forPluginID pluginID: String, permissionID: String) {
        guard activePlugins.contains(where: { plugin in
            plugin.metadata.id == pluginID
                && (guardedValue(
                    for: plugin,
                    operation: "read permission requirements",
                    plugin.permissionRequirements
                ) ?? []).contains(where: { $0.id == permissionID })
        }) else {
            return
        }

        presentPluginConfiguration(pluginID: pluginID)
    }

    private func permissionActionTitle(
        for kind: PluginPermissionKind,
        isGranted: Bool
    ) -> String {
        switch kind {
        case .accessibility:
            return isGranted
                ? AppL10n.plugins("plugin.permission.checkStatus", defaultValue: "检查授权状态")
                : AppL10n.plugins("plugin.permission.openAuthorization", defaultValue: "前往授权")
        case .inputMonitoring:
            return isGranted
                ? AppL10n.plugins("plugin.permission.checkStatus", defaultValue: "检查授权状态")
                : AppL10n.plugins("plugin.permission.openAuthorization", defaultValue: "前往授权")
        case .calendarFullAccess:
            return isGranted
                ? AppL10n.plugins("plugin.permission.checkStatus", defaultValue: "检查授权状态")
                : AppL10n.plugins("plugin.permission.requestAuthorization", defaultValue: "请求授权")
        case .automation:
            return AppL10n.plugins("plugin.permission.openSettings", defaultValue: "打开设置")
        case .screenRecording:
            return isGranted
                ? AppL10n.plugins("plugin.permission.checkStatus", defaultValue: "检查授权状态")
                : AppL10n.plugins("plugin.permission.openAuthorization", defaultValue: "前往授权")
        }
    }

    private func permissionIconName(for kind: PluginPermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "accessibility"
        case .inputMonitoring:
            return "keyboard.badge.eye"
        case .calendarFullAccess:
            return "calendar"
        case .automation:
            return "cursorarrow.click.2"
        case .screenRecording:
            return "rectangle.dashed.badge.record"
        }
    }
}
