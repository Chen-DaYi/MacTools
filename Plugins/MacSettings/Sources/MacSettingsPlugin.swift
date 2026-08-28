import AppKit
import Foundation
import IOKit.hid
import SwiftUI
import MacToolsPluginKit

@MainActor
private final class MacSettingsInputDeviceObserver {
    private var manager: IOHIDManager?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceChanged, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func notifyChange() {
        onChange()
    }

    private nonisolated(unsafe) static let deviceChanged: IOHIDDeviceCallback = {
        context,
        _,
        _,
        _ in
        guard let context else { return }
        let observer = Unmanaged<MacSettingsInputDeviceObserver>
            .fromOpaque(context)
            .takeUnretainedValue()
        Task { @MainActor in
            observer.notifyChange()
        }
    }
}

@MainActor
final class MacSettingsActionContextBox {
    var context: PluginActionExecutionHostContext?
}

public final class MacSettingsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        try MainActor.assumeIsolated {
            try MacSettingsPluginProvider(context: context)
        }
    }
}

@MainActor
private struct MacSettingsPluginProvider: PluginProvider {
    let plugin: MacSettingsPlugin

    init(context: PluginRuntimeContext) throws {
        let actionContextBox = MacSettingsActionContextBox()
        let catalog = try MacSettingsCatalogFactory.make {
            actionContextBox.context
        }
        let controller = MacSettingsController(
            catalog: catalog,
            storage: context.storage
        )
        plugin = MacSettingsPlugin(
            controller: controller,
            actionContextBox: actionContextBox,
            localization: PluginLocalization(bundle: context.resourceBundle)
        )
    }

    func makePlugins() -> [any MacToolsPlugin] {
        [plugin]
    }
}

@MainActor
final class MacSettingsPlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginSettingsPresenting,
    PluginSettingsSearchFocusing,
    PluginActionProviding,
    PluginActionExecutionHostContextConsuming,
    PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding,
    PluginActionReferenceBackupProviding,
    PluginPersistentPreferencesChangeSignaling
{
    private enum ActionID {
        static let open = "open"
        static let openFavorites = "open-favorites"
        static let openCategory = "open-category"
        static let openSetting = "open-setting"
        static let search = "search"
        static let setBoolean = "set-boolean"
        static let applyProfile = "apply-profile"
        static let undo = "undo-most-recent-change"
        static let category = "category"
        static let query = "query"
        static let settingID = "setting-id"
        static let enabled = "enabled"
        static let profileID = "profile-id"
    }

    private enum ControlID {
        static let settingPrefix = "favorite-setting."
        static let openAll = "open-all-settings"
    }

    private struct PortablePreferences: Codable {
        let version: Int
        let favorites: [SystemSettingID]
        let density: MacSettingsWorkspaceDensity
        let profiles: [SystemSettingsProfile]
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)? {
        didSet { controller.onPersistentPreferencesChange = onPersistentPreferencesChange }
    }
    var actionExecutionHostContext: PluginActionExecutionHostContext? {
        didSet {
            actionContextBox.context = actionExecutionHostContext
            updateProviderAvailability()
        }
    }

    private let controller: MacSettingsController
    private let actionContextBox: MacSettingsActionContextBox
    private let localization: PluginLocalization
    private let openSystemSettings: (URL) -> Void
    private var isExpanded = false
    private var inputDeviceObserver: MacSettingsInputDeviceObserver?
    private nonisolated(unsafe) var externalObservers: [NSObjectProtocol] = []

    init(
        controller: MacSettingsController,
        actionContextBox: MacSettingsActionContextBox = MacSettingsActionContextBox(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        openSystemSettings: @escaping (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        }
    ) {
        self.controller = controller
        self.actionContextBox = actionContextBox
        self.localization = localization
        self.openSystemSettings = openSystemSettings
        self.metadata = PluginMetadata(
            id: "mac-settings",
            title: localization.string("metadata.title", defaultValue: "Mac 设置"),
            iconName: "slider.horizontal.3",
            iconTint: .accentColor,
            order: 18,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "搜索并集中调整当前 Mac 的常用设置"
            )
        )
        controller.onStateChange = { [weak self] in self?.onStateChange?() }
        controller.onPersistentPreferencesChange = { [weak self] in
            self?.onPersistentPreferencesChange?()
        }
        controller.onPermissionAction = { [weak self] permissionID in
            self?.handlePermissionAction(id: permissionID)
        }
        controller.onOpenSystemSettings = openSystemSettings
        inputDeviceObserver = MacSettingsInputDeviceObserver { [weak controller] in
            controller?.scheduleExternalRefresh()
        }
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "\(controller.favoriteIDs.count) 个收藏 · \(controller.attentionCount) 项需关注",
            isOn: controller.attentionCount > 0,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? featurePanelDetail : nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        let affectedSettings = settingsRequiringPermission(MacSettingsPermission.fullDiskAccess)
            .map(\.definition.title)
            .joined(separator: "、")
        guard !affectedSettings.isEmpty else { return [] }
        return [
            PluginPermissionRequirement(
                id: MacSettingsPermission.fullDiskAccess,
                // PluginKit v5 has no Full Disk Access case. The host recognizes the stable
                // permission ID and supplies the correct shared presentation and action copy.
                kind: .automation,
                title: localization.string(
                    "permission.fullDiskAccess.title",
                    defaultValue: "完全磁盘访问"
                ),
                description: localization.format(
                    "permission.fullDiskAccess.descriptionFormat",
                    defaultValue: "用于更改受 macOS 保护的设置。当前需要此权限：%@。",
                    affectedSettings
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .selfManaged) { _ in
            MacSettingsWorkspaceView(controller: self.controller)
        }
        .onVisibilityChange { [weak controller] visible in
            if visible { controller?.refresh() } else { controller?.cancelRefresh() }
        }
    }

    var actionDefinitions: [ActionDefinition] {
        [
            navigationAction(
                id: ActionID.open,
                title: "打开 Mac 设置",
                description: metadata.defaultDescription,
                parameters: []
            ),
            navigationAction(
                id: ActionID.openFavorites,
                title: "打开 Mac 设置收藏",
                description: "打开可直接控制的常用设置。",
                parameters: []
            ),
            navigationAction(
                id: ActionID.openCategory,
                title: "打开 Mac 设置类别",
                description: "打开指定的 Mac 设置类别。",
                parameters: [
                    ActionParameterDefinition(
                        id: ActionID.category,
                        title: "类别",
                        kind: .string
                    ),
                ]
            ),
            navigationAction(
                id: ActionID.openSetting,
                title: "打开 Mac 设置项目",
                description: "打开指定的 Mac 设置并保留可直接使用的控件。",
                parameters: [
                    ActionParameterDefinition(
                        id: ActionID.settingID,
                        title: "设置 ID",
                        kind: .string
                    ),
                ]
            ),
            navigationAction(
                id: ActionID.search,
                title: "搜索 Mac 设置",
                description: "打开 Mac 设置并搜索标题、说明和别名。",
                parameters: [
                    ActionParameterDefinition(
                        id: ActionID.query,
                        title: "搜索内容",
                        kind: .string,
                        isRequired: false
                    ),
                ]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setBoolean),
                title: "设置 Mac 布尔设置",
                description: "明确打开或关闭支持的 Mac 设置。",
                keywords: ["Mac 设置", "打开设置", "关闭设置"],
                systemImage: "switch.2",
                parameters: [
                    ActionParameterDefinition(id: ActionID.settingID, title: "设置 ID", kind: .string),
                    ActionParameterDefinition(id: ActionID.enabled, title: "打开", kind: .boolean),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.applyProfile),
                title: "应用 Mac 设置配置",
                description: "预览并应用已保存的设置配置。",
                keywords: ["配置", "profile", "应用设置"],
                systemImage: "square.stack.3d.up",
                parameters: [
                    ActionParameterDefinition(id: ActionID.profileID, title: "配置 ID", kind: .string),
                ],
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: "应用 Mac 设置配置？",
                    message: "MacTools 将打开配置预览。确认选择后，所选设置才会更改。",
                    confirmButtonTitle: "打开预览"
                ),
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.undo),
                title: "撤销最近的 Mac 设置更改",
                description: "恢复最近一个支持回滚的设置。",
                keywords: ["撤销设置", "undo setting", "恢复"],
                systemImage: "arrow.uturn.backward",
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(reference: reference(ActionID.open), title: "打开 Mac 设置"),
            ActionCatalogEntry(reference: reference(ActionID.openFavorites), title: "打开 Mac 设置收藏"),
            ActionCatalogEntry(reference: reference(ActionID.undo), title: "撤销最近的 Mac 设置更改"),
        ] + controller.availableCategories.map { category in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: ActionID.openCategory),
                    parameters: try! ActionParameterSet([
                        ActionID.category: .string(category.rawValue),
                    ])
                ),
                title: "打开类别 · \(category.title)"
            )
        } + controller.catalog.records.map { record in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: ActionID.openSetting),
                    parameters: try! ActionParameterSet([
                        ActionID.settingID: .string(record.id.rawValue),
                    ])
                ),
                title: "打开设置 · \(record.definition.title)"
            )
        } + controller.profiles.map { profile in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: ActionID.applyProfile),
                    parameters: try! ActionParameterSet([
                        ActionID.profileID: .string(profile.id.uuidString.lowercased()),
                    ])
                ),
                title: "应用配置 · \(profile.name)"
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        switch reference.key.actionID {
        case ActionID.undo:
            return controller.history.contains(where: \.canRollback)
                ? .available
                : .unavailable("没有可撤销的更改。")
        case ActionID.setBoolean:
            guard let settingID = stringParameter(ActionID.settingID, in: reference),
                  case .boolean? = reference.parameters[ActionID.enabled],
                  let record = controller.catalog[SystemSettingID(rawValue: settingID)],
                  case .boolean = record.definition.schema,
                  let state = controller.rowStates[record.id],
                  state.errorMessage == nil,
                  !state.isApplying,
                  isControllable(state.availability) else {
                return .unavailable("此设置当前不可用。")
            }
            return .available
        case ActionID.applyProfile:
            guard let profileID = stringParameter(ActionID.profileID, in: reference),
                  let uuid = UUID(uuidString: profileID),
                  controller.profiles.contains(where: { $0.id == uuid }) else {
                return .unavailable("配置不可用。")
            }
            return .available
        case ActionID.openSetting:
            guard let settingID = stringParameter(ActionID.settingID, in: reference),
                  controller.catalog[SystemSettingID(rawValue: settingID)] != nil else {
                return .unavailable("设置不可用。")
            }
            return .available
        default:
            return .available
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        switch invocation.reference.key.actionID {
        case ActionID.open:
            return navigationHandle(destination: .all)
        case ActionID.openFavorites:
            return navigationHandle(destination: .favorites)
        case ActionID.openCategory:
            guard let rawCategory = stringParameter(ActionID.category, in: invocation.reference),
                  let category = SystemSettingCategory(rawValue: rawCategory) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return navigationHandle(destination: .category(category))
        case ActionID.openSetting:
            guard let rawID = stringParameter(ActionID.settingID, in: invocation.reference),
                  let record = controller.catalog[SystemSettingID(rawValue: rawID)] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                controller.destination = .category(record.definition.category)
                controller.searchText = record.definition.title
                requestSettingsPresentation?()
                return .succeeded()
            }
        case ActionID.search:
            let query = stringParameter(ActionID.query, in: invocation.reference) ?? ""
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                controller.destination = .all
                controller.searchText = query
                controller.requestSearchFocus()
                requestSettingsPresentation?()
                return .succeeded()
            }
        case ActionID.setBoolean:
            guard let rawID = stringParameter(ActionID.settingID, in: invocation.reference),
                  case let .boolean(enabled)? = invocation.reference.parameters[ActionID.enabled],
                  let record = controller.catalog[SystemSettingID(rawValue: rawID)],
                  case .boolean = record.definition.schema else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak controller] in
                guard let controller else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                return await controller.applyAndWait(.boolean(enabled), to: record)
                    ? .succeeded()
                    : .failed(message: controller.rowStates[record.id]?.errorMessage ?? PluginKitLocalization.actionFailed)
            }
        case ActionID.applyProfile:
            guard let rawID = stringParameter(ActionID.profileID, in: invocation.reference),
                  let id = UUID(uuidString: rawID),
                  let profile = controller.profiles.first(where: { $0.id == id }) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                controller.preparePlan(for: profile)
                controller.destination = .profiles
                requestSettingsPresentation?()
                return .succeeded(message: "请预览并选择要应用的更改。")
            }
        case ActionID.undo:
            return ActionExecutionHandle { [weak controller] in
                guard let controller else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                return await controller.undoMostRecentChange()
                    ? .succeeded()
                    : .failed(message: "没有可撤销的更改。")
            }
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
    }

    func refresh() {
        controller.refresh()
    }

    func activate(context: PluginRuntimeContext) {
        controller.activate()
        guard externalObservers.isEmpty else { return }
        inputDeviceObserver?.start()
        let center = NotificationCenter.default
        externalObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            Task { @MainActor in controller?.scheduleExternalRefresh() }
        })
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.deactivate()
        inputDeviceObserver?.stop()
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        for observer in externalObservers {
            center.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        externalObservers = []
    }

    func focusSettingsSearch() {
        controller.requestSearchFocus()
    }

    func actionExecutionCatalogDidChange() {
        updateProviderAvailability()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if expanded { controller.refresh() }
            onStateChange?()
        case let .invokeAction(controlID):
            if controlID == ControlID.openAll {
                controller.destination = .all
                requestSettingsPresentation?()
            } else if let record = favoriteRecord(controlID),
                      case let .boolean(value)? = controller.rowStates[record.id]?.value {
                controller.apply(.boolean(!value), to: record.id)
            }
        case let .setSelection(controlID, optionID):
            if let record = favoriteRecord(controlID) {
                controller.apply(.choice(id: optionID), to: record.id)
            }
        case let .setSlider(controlID, value, phase):
            guard phase == .ended, let record = favoriteRecord(controlID) else { return }
            switch record.definition.schema {
            case .integer:
                controller.apply(.integer(Int(value.rounded())), to: record.id)
            case .decimal:
                controller.apply(.decimal(value), to: record.id)
            default:
                break
            }
        case .setSwitch, .setNavigationSelection, .clearNavigationSelection, .setDate:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == MacSettingsPermission.fullDiskAccess else {
            return .init(isGranted: true, footnote: nil)
        }
        let isGranted = controller.isPermissionGranted(permissionID)
        return .init(
            isGranted: isGranted,
            footnote: isGranted ? nil : localization.string(
                "permission.fullDiskAccess.footnote",
                defaultValue: "在系统设置中授权后，请退出并重新打开 MacTools。"
            )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == MacSettingsPermission.fullDiskAccess,
              let url = MacSettingsPermission.fullDiskAccessSettingsURL else { return }
        openSystemSettings(url)
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    private func settingsRequiringPermission(
        _ permissionID: String
    ) -> [SystemSettingRecord] {
        controller.catalog.records.filter {
            $0.definition.requirements.requiredPermissionID == permissionID
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        let payload = PortablePreferences(
            version: 1,
            favorites: controller.favoriteIDs,
            density: controller.density,
            profiles: controller.profiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              data.count <= SystemSettingsProfileCodec.maximumFileSize else { return nil }
        return data
    }

    func restorePortablePreferences(from data: Data) {
        _ = restorePortablePreferencesReportingResult(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard data.count <= SystemSettingsProfileCodec.maximumFileSize else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PortablePreferences.self, from: data),
              payload.version == 1,
              payload.profiles.allSatisfy({
                  SystemSettingsProfileCodec.validate($0, catalog: controller.catalog).isValid
              }) else { return false }
        let favoriteSet = Set(payload.favorites)
        for id in controller.favoriteIDs where !favoriteSet.contains(id) {
            controller.toggleFavorite(id)
        }
        for id in payload.favorites where !controller.favoriteIDs.contains(id) {
            controller.toggleFavorite(id)
        }
        controller.setDensity(payload.density)
        for profile in payload.profiles {
            guard controller.restorePortableProfile(profile) else { return false }
        }
        return true
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        guard data.count <= SystemSettingsProfileCodec.maximumFileSize else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PortablePreferences.self, from: data),
              payload.version == 1 else { return nil }
        return payload.profiles.map { profile in
            ActionReference(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.applyProfile),
                parameters: try! ActionParameterSet([
                    ActionID.profileID: .string(profile.id.uuidString.lowercased()),
                ])
            )
        }
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        guard reference.key.providerID == metadata.id else { return .excluded }
        switch reference.key.actionID {
        case ActionID.applyProfile:
            return .requiresPluginPreferences
        case ActionID.undo:
            return .excluded
        case ActionID.open, ActionID.openFavorites, ActionID.openCategory, ActionID.openSetting,
             ActionID.search, ActionID.setBoolean:
            return .selfContained
        default:
            return .excluded
        }
    }

    private var featurePanelDetail: PluginPanelDetail {
        let favoriteControls = controller.favoriteRecordsForFeaturePanel.compactMap(featureControl)
        let openControl = PluginPanelControl(
            id: ControlID.openAll,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: "打开所有设置…",
            actionIconSystemName: "arrow.up.forward.app",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: !favoriteControls.isEmpty,
            isEnabled: true
        )
        return PluginPanelDetail(controls: favoriteControls + [openControl])
    }

    private func featureControl(_ record: SystemSettingRecord) -> PluginPanelControl? {
        guard let state = controller.rowStates[record.id], let value = state.value else { return nil }
        let id = ControlID.settingPrefix + record.id.rawValue
        let enabled = isControllable(state.availability)
            && state.errorMessage == nil
            && !state.isApplying
            && !controller.isApplyingProfile
        switch (record.definition.schema, value) {
        case let (.boolean, .boolean(isOn)):
            return PluginPanelControl(
                id: id,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: "\(record.definition.title) · \(isOn ? "开" : "关")",
                actionIconSystemName: isOn ? "checkmark.circle.fill" : "circle",
                isEnabled: enabled
            )
        case let (.choice(options), .choice(selectionID)):
            return PluginPanelControl(
                id: id,
                kind: options.count > 3 ? .selectList : .segmented,
                options: options.map { .init(id: $0.id, title: $0.title) },
                selectedOptionID: selectionID,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: record.definition.title,
                isEnabled: enabled
            )
        case let (.integer(range, step), .integer(integer)):
            return sliderControl(
                id: id,
                title: record.definition.title,
                value: Double(integer),
                bounds: Double(range.lowerBound) ... Double(range.upperBound),
                step: Double(step),
                enabled: enabled
            )
        case let (.decimal(range, step), .decimal(value)):
            return sliderControl(
                id: id,
                title: record.definition.title,
                value: value,
                bounds: range,
                step: step ?? 0.01,
                enabled: enabled
            )
        default:
            return PluginPanelControl(
                id: ControlID.openAll,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: "\(record.definition.title) · \(value.conciseDescription)",
                actionIconSystemName: "arrow.up.forward.app",
                isEnabled: true
            )
        }
    }

    private func sliderControl(
        id: String,
        title: String,
        value: Double,
        bounds: ClosedRange<Double>,
        step: Double,
        enabled: Bool
    ) -> PluginPanelControl {
        PluginPanelControl(
            id: id,
            kind: .slider,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: title,
            sliderValue: value,
            sliderBounds: bounds,
            sliderStep: step,
            valueLabel: value.formatted(.number.precision(.fractionLength(0 ... 1))),
            isEnabled: enabled
        )
    }

    private func favoriteRecord(_ controlID: String) -> SystemSettingRecord? {
        guard controlID.hasPrefix(ControlID.settingPrefix) else { return nil }
        return controller.catalog[
            SystemSettingID(rawValue: String(controlID.dropFirst(ControlID.settingPrefix.count)))
        ]
    }

    private func updateProviderAvailability() {
        let providerIDs = [
            "appearance",
            "auto-hide-dock",
            "auto-hide-menu-bar",
            "display-true-color",
            "night-shift",
            "stage-manager",
        ]
        let available = Set(providerIDs.filter { providerID in
            let reference = ActionReference(
                key: ActionKey(providerID: providerID, actionID: "set-enabled"),
                parameters: try! ActionParameterSet(["enabled": .boolean(true)])
            )
            return actionExecutionHostContext?.item(for: reference) != nil
        })
        controller.updateAvailableProviderIDs(available)
    }

    private func navigationHandle(destination: MacSettingsDestination) -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
            controller.destination = destination
            requestSettingsPresentation?()
            return .succeeded()
        }
    }

    private func navigationAction(
        id: String,
        title: String,
        description: String,
        parameters: [ActionParameterDefinition]
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: id),
            title: title,
            description: description,
            keywords: ["Mac 设置", "系统设置", "settings"],
            systemImage: metadata.iconName,
            parameters: parameters,
            externalInvocationPolicy: .allowed,
            capabilities: [.foregroundInteractive]
        )
    }

    private func reference(_ actionID: String) -> ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: actionID))
    }

    private func stringParameter(_ id: String, in reference: ActionReference) -> String? {
        guard case let .string(value)? = reference.parameters[id] else { return nil }
        return value
    }

    private func isControllable(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart: true
        default: false
        }
    }
}
