import AppKit
import Combine
import Foundation
import MacToolsPluginKit

enum MacSettingsDestination: Hashable, Identifiable {
    case all
    case favorites
    case recent
    case attention
    case category(SystemSettingCategory)
    case profiles
    case importExport
    case history

    var id: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .recent: "recent"
        case .attention: "attention"
        case let .category(category): "category.\(category.rawValue)"
        case .profiles: "profiles"
        case .importExport: "import-export"
        case .history: "history"
        }
    }
}

enum MacSettingsWorkspaceDensity: String, CaseIterable, Codable, Identifiable {
    case comfortable
    case compact

    var id: String { rawValue }
}

enum SystemSettingRowVerification: Equatable {
    case verified
    case unverified
    case failed
}

struct SystemSettingRowState: Equatable {
    var value: SystemSettingValue?
    var availability: SystemSettingAvailability
    var isLoading: Bool
    var isApplying: Bool
    var verification: SystemSettingRowVerification?
    var errorMessage: String?
    var changedAt: Date?
}

struct SystemSettingsImportPreview: Equatable {
    let profile: SystemSettingsProfile
    let validation: SystemSettingsProfileValidationResult
}

@MainActor
final class MacSettingsController: ObservableObject {
    private enum StorageKey {
        static let favorites = "favorite-setting-ids"
        static let density = "workspace-density"
    }

    let catalog: SystemSettingCatalog

    @Published var destination: MacSettingsDestination = .all
    @Published var searchText = ""
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var rowStates: [SystemSettingID: SystemSettingRowState] = [:]
    @Published private(set) var favoriteIDs: [SystemSettingID]
    @Published private(set) var history: [SystemSettingChange]
    @Published private(set) var profiles: [SystemSettingsProfile]
    @Published private(set) var importedPreview: SystemSettingsImportPreview?
    @Published private(set) var activePlan: SystemSettingsProfileApplyPlan?
    @Published private(set) var lastApplyReport: SystemSettingsProfileApplyReport?
    @Published private(set) var density: MacSettingsWorkspaceDensity
    @Published private(set) var isRefreshing = false
    @Published private(set) var profileErrorMessage: String?


    var onStateChange: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)?
    var onPermissionAction: ((String) -> Void)?

    private let storage: any PluginStorage
    private let historyStore: any SystemSettingChangeHistoryStoring
    private let profileStore: any SystemSettingsProfileStoring
    private let applyCoordinator: SystemSettingsProfileApplyCoordinator
    private var environment: SystemSettingEnvironment
    private var refreshTask: Task<Void, Never>?
    private var externalRefreshTask: Task<Void, Never>?
    private var pendingRequirementIDs: Set<SystemSettingID> = []
    private var failedSettingIDs: Set<SystemSettingID> = []

    init(
        catalog: SystemSettingCatalog,
        storage: any PluginStorage,
        historyStore: (any SystemSettingChangeHistoryStoring)? = nil,
        profileStore: (any SystemSettingsProfileStoring)? = nil,
        environment: SystemSettingEnvironment = .current
    ) {
        self.catalog = catalog
        self.storage = storage
        self.historyStore = historyStore ?? SystemSettingChangeHistoryStore(storage: storage)
        self.profileStore = profileStore ?? SystemSettingsProfileStore(storage: storage)
        self.applyCoordinator = SystemSettingsProfileApplyCoordinator(catalog: catalog)
        self.environment = environment
        let validIDs = Set(catalog.records.map(\.id))
        self.favoriteIDs = (storage.stringArray(forKey: StorageKey.favorites) ?? [])
            .map { SystemSettingID(rawValue: $0) }
            .filter(validIDs.contains)
        self.density = MacSettingsWorkspaceDensity(
            rawValue: storage.string(forKey: StorageKey.density) ?? ""
        ) ?? .comfortable
        self.history = self.historyStore.load(referenceDate: Date())
        self.profiles = self.profileStore.load()
        for record in catalog.records {
            rowStates[record.id] = .init(
                value: record.definition.defaultValue,
                availability: SystemSettingCompatibilityEvaluator.availability(
                    for: record.definition,
                    environment: environment
                ),
                isLoading: record.definition.executionClass != .guidedManual
                    && record.definition.executionClass != .unsupported,
                isApplying: false,
                verification: nil,
                errorMessage: nil,
                changedAt: history.first(where: { $0.settingID == record.id })?.date
            )
        }
    }

    deinit {
        refreshTask?.cancel()
        externalRefreshTask?.cancel()
    }

    var visibleRecords: [SystemSettingRecord] {
        var records: [SystemSettingRecord]
        switch destination {
        case .all:
            records = catalog.records
        case .favorites:
            let order = Dictionary(uniqueKeysWithValues: favoriteIDs.enumerated().map { ($1, $0) })
            records = catalog.records
                .filter { order[$0.id] != nil }
                .sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
        case .recent:
            var recentIDs: [SystemSettingID] = []
            for change in history where !recentIDs.contains(change.settingID) {
                recentIDs.append(change.settingID)
            }
            let order = Dictionary(uniqueKeysWithValues: recentIDs.enumerated().map { ($1, $0) })
            records = catalog.records
                .filter { order[$0.id] != nil }
                .sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
        case .attention:
            records = catalog.records.filter { needsAttention($0.id) }
        case let .category(category):
            records = catalog.records.filter { $0.definition.category == category }
        case .profiles, .importExport, .history:
            records = []
        }
        return catalog.search(searchText, in: records)
    }

    var favoriteRecordsForFeaturePanel: [SystemSettingRecord] {
        let favoriteSet = Set(favoriteIDs.prefix(4))
        return favoriteIDs.prefix(4).compactMap { id in
            guard favoriteSet.contains(id) else { return nil }
            return catalog[id]
        }
    }

    var attentionCount: Int {
        catalog.records.lazy.filter { self.needsAttention($0.id) }.count
    }

    var availableCategories: [SystemSettingCategory] {
        SystemSettingCategory.allCases.filter { category in
            catalog.records.contains { $0.definition.category == category }
        }
    }

    var builtInTemplates: [SystemSettingsProfile] {
        BuiltInSystemSettingsProfiles.templates(catalog: catalog)
    }

    func requestSearchFocus() {
        destination = .all
        searchFocusRequest &+= 1
    }

    func updateAvailableProviderIDs(_ providerIDs: Set<String>) {
        guard environment.availableProviderIDs != providerIDs else { return }
        environment = SystemSettingEnvironment(
            systemVersion: environment.systemVersion,
            availableHardware: environment.availableHardware,
            grantedPermissionIDs: environment.grantedPermissionIDs,
            availableProviderIDs: providerIDs
        )
        for record in catalog.records {
            rowStates[record.id]?.availability = SystemSettingCompatibilityEvaluator.availability(
                for: record.definition,
                environment: environment
            )
        }
        onStateChange?()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isRefreshing = true
            defer { isRefreshing = false }
            for record in catalog.records {
                guard !Task.isCancelled else { return }
                await refresh(record)
                await Task.yield()
            }
            onStateChange?()
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
        isRefreshing = false
    }

    func scheduleExternalRefresh() {
        externalRefreshTask?.cancel()
        externalRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh(_ record: SystemSettingRecord) async {
        let availability = SystemSettingCompatibilityEvaluator.availability(
            for: record.definition,
            environment: environment
        )
        rowStates[record.id]?.availability = availability
        guard canRead(availability),
              record.definition.executionClass != .guidedManual,
              record.definition.executionClass != .unsupported else {
            rowStates[record.id]?.isLoading = false
            return
        }
        rowStates[record.id]?.isLoading = true
        do {
            let value = try await record.adapter.read()
            guard record.definition.schema.accepts(value) else {
                throw SystemSettingAdapterError.invalidValue
            }
            rowStates[record.id]?.value = value
            rowStates[record.id]?.errorMessage = nil
            failedSettingIDs.remove(record.id)
        } catch {
            rowStates[record.id]?.errorMessage = error.localizedDescription
            failedSettingIDs.insert(record.id)
        }
        rowStates[record.id]?.isLoading = false
    }

    func apply(_ value: SystemSettingValue, to settingID: SystemSettingID) {
        guard let record = catalog[settingID],
              record.definition.schema.accepts(value),
              let state = rowStates[settingID],
              canApply(state.availability) else { return }
        Task { @MainActor [weak self] in
            await self?.applyAndWait(value, to: record)
        }
    }

    @discardableResult
    func applyAndWait(
        _ value: SystemSettingValue,
        to record: SystemSettingRecord
    ) async -> Bool {
        guard record.definition.schema.accepts(value),
              let state = rowStates[record.id],
              canApply(state.availability) else { return false }
        let previousValue: SystemSettingValue
        do {
            previousValue = try await record.adapter.read()
        } catch {
            guard let cached = state.value else { return false }
            previousValue = cached
        }

        rowStates[record.id]?.value = value
        rowStates[record.id]?.isApplying = true
        rowStates[record.id]?.errorMessage = nil
        defer { rowStates[record.id]?.isApplying = false }
        do {
            try await record.adapter.apply(value)
            let verification = try await record.adapter.verify(value)
            switch verification {
            case .verified:
                rowStates[record.id]?.verification = .verified
                rowStates[record.id]?.value = value
            case .unavailable:
                rowStates[record.id]?.verification = .unverified
            case let .mismatch(actual):
                let rolledBack = await rollbackAfterFailedApply(
                    record: record,
                    previousValue: previousValue
                )
                rowStates[record.id]?.value = rolledBack ? previousValue : actual
                rowStates[record.id]?.verification = .failed
                rowStates[record.id]?.errorMessage = rolledBack
                    ? "验证失败，已恢复原值。"
                    : "验证失败：当前值为 \(actual.conciseDescription)，自动恢复失败。"
                failedSettingIDs.insert(record.id)
                onStateChange?()
                return false
            }
            failedSettingIDs.remove(record.id)
            if record.definition.executionClass == .directRequiresLogout
                || record.definition.executionClass == .directRequiresRestart {
                pendingRequirementIDs.insert(record.id)
            }
            if previousValue != value, !record.definition.isSensitive {
                let change = SystemSettingChange(
                    settingID: record.id,
                    settingTitle: record.definition.title,
                    previousValue: previousValue,
                    newValue: value,
                    verification: verification == .unavailable ? .unverified : .verified,
                    canRollback: record.definition.canRollback
                )
                history = historyStore.append(change, referenceDate: change.date)
                rowStates[record.id]?.changedAt = change.date
            }
            onStateChange?()
            return true
        } catch {
            let rolledBack = await rollbackAfterFailedApply(
                record: record,
                previousValue: previousValue
            )
            if rolledBack {
                rowStates[record.id]?.value = previousValue
            }
            rowStates[record.id]?.verification = .failed
            rowStates[record.id]?.errorMessage = rolledBack
                ? "\(error.localizedDescription) 已恢复原值。"
                : "\(error.localizedDescription) 自动恢复失败。"
            failedSettingIDs.insert(record.id)
            onStateChange?()
            return false
        }
    }

    private func rollbackAfterFailedApply(
        record: SystemSettingRecord,
        previousValue: SystemSettingValue
    ) async -> Bool {
        guard record.definition.canRollback else { return false }
        do {
            try await record.adapter.rollback(to: previousValue)
            guard case .verified = try await record.adapter.verify(previousValue) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    func toggleFavorite(_ settingID: SystemSettingID) {
        if let index = favoriteIDs.firstIndex(of: settingID) {
            favoriteIDs.remove(at: index)
        } else if catalog[settingID] != nil {
            favoriteIDs.append(settingID)
        }
        persistFavorites()
    }

    func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        favoriteIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistFavorites()
    }

    func moveFavorite(_ settingID: SystemSettingID, by offset: Int) {
        guard let index = favoriteIDs.firstIndex(of: settingID) else { return }
        let destination = index + offset
        guard favoriteIDs.indices.contains(destination) else { return }
        favoriteIDs.swapAt(index, destination)
        persistFavorites()
    }

    func setDensity(_ density: MacSettingsWorkspaceDensity) {
        self.density = density
        storage.set(density.rawValue, forKey: StorageKey.density)
        onPersistentPreferencesChange?()
    }

    func clearHistory() {
        historyStore.clear()
        history = []
        for id in rowStates.keys {
            rowStates[id]?.changedAt = nil
        }
        onStateChange?()
    }

    func rollback(_ change: SystemSettingChange) {
        guard change.canRollback, let record = catalog[change.settingID] else { return }
        apply(change.previousValue, to: record.id)
    }

    func openSystemSettings(for settingID: SystemSettingID) {
        if case let .permissionMissing(permissionID) = rowStates[settingID]?.availability {
            if let onPermissionAction {
                onPermissionAction(permissionID)
            } else if permissionID == MacSettingsPermission.fullDiskAccess,
                      let url = MacSettingsPermission.fullDiskAccessSettingsURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let url = catalog[settingID]?.definition.destination?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func isPermissionGranted(_ permissionID: String) -> Bool {
        environment.grantedPermissionIDs.contains(permissionID)
    }

    func makeDraft(from profile: SystemSettingsProfile? = nil) -> SystemSettingsProfileDraft {
        let entryByID = Dictionary(uniqueKeysWithValues: (profile?.entries ?? []).map { ($0.settingID, $0) })
        return SystemSettingsProfileDraft(
            name: profile?.name ?? "新配置",
            profileDescription: profile?.profileDescription ?? "",
            items: catalog.records.filter(\.definition.isProfileEligible).map { record in
                let existing = entryByID[record.id]
                return .init(
                    settingID: record.id,
                    isIncluded: existing != nil,
                    desiredValue: existing?.desiredValue
                        ?? rowStates[record.id]?.value
                        ?? record.definition.defaultValue
                        ?? .string("")
                )
            }
        )
    }

    @discardableResult
    func saveDraft(
        _ draft: SystemSettingsProfileDraft,
        replacing profile: SystemSettingsProfile? = nil
    ) -> Bool {
        let saved = draft.makeProfile(existing: profile, catalog: catalog)
        let validation = SystemSettingsProfileCodec.validate(saved, catalog: catalog)
        guard validation.isValid, !saved.entries.isEmpty, profileStore.save(saved) else {
            profileErrorMessage = "配置至少需要包含一个有效设置。"
            return false
        }
        profiles = profileStore.load()
        profileErrorMessage = nil
        onPersistentPreferencesChange?()
        onStateChange?()
        return true
    }

    func saveTemplate(_ template: SystemSettingsProfile) {
        var copy = template
        copy = SystemSettingsProfile(
            name: template.name,
            profileDescription: template.profileDescription,
            entries: template.entries
        )
        if profileStore.save(copy) {
            profiles = profileStore.load()
            onPersistentPreferencesChange?()
            onStateChange?()
        }
    }

    func removeProfile(_ profile: SystemSettingsProfile) {
        guard profileStore.remove(id: profile.id) else { return }
        profiles = profileStore.load()
        if importedPreview?.profile.id == profile.id { importedPreview = nil }
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func importProfile(data: Data) {
        do {
            let decoded = try SystemSettingsProfileCodec.decode(data, catalog: catalog)
            importedPreview = .init(profile: decoded.0, validation: decoded.1)
            activePlan = makePlan(for: decoded.0)
            profileErrorMessage = nil
        } catch {
            importedPreview = nil
            activePlan = nil
            profileErrorMessage = "无法导入配置：\(error.localizedDescription)"
        }
    }

    func acceptImportedProfile() {
        guard let profile = importedPreview?.profile, profileStore.save(profile) else { return }
        profiles = profileStore.load()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func exportData(for profile: SystemSettingsProfile) throws -> Data {
        try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
    }

    func makePlan(for profile: SystemSettingsProfile) -> SystemSettingsProfileApplyPlan {
        SystemSettingsProfilePlanner.makePlan(
            profile: profile,
            catalog: catalog,
            currentValues: rowStates.compactMapValues(\.value),
            availability: rowStates.mapValues(\.availability)
        )
    }

    func preparePlan(for profile: SystemSettingsProfile) {
        activePlan = makePlan(for: profile)
        lastApplyReport = nil
    }

    func updatePlanSelection(_ selectedIDs: Set<SystemSettingID>) {
        activePlan = activePlan?.selecting(selectedIDs)
    }

    func applyActivePlan() {
        guard let plan = activePlan else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await applyCoordinator.apply(plan: plan)
            lastApplyReport = report
            for result in report.results {
                if [.appliedAndVerified, .pendingLogout, .pendingRestart, .verificationUnavailable].contains(result.kind),
                   let item = plan.items.first(where: { $0.settingID == result.settingID }),
                   let previous = item.currentValue,
                   previous != item.desiredValue,
                   let record = catalog[result.settingID],
                   !record.definition.isSensitive {
                    let change = SystemSettingChange(
                        settingID: result.settingID,
                        settingTitle: result.title,
                        previousValue: previous,
                        newValue: item.desiredValue,
                        verification: result.kind == .verificationUnavailable ? .unverified : .verified,
                        canRollback: record.definition.canRollback
                    )
                    history = historyStore.append(change, referenceDate: change.date)
                    rowStates[result.settingID]?.changedAt = change.date
                }
                if let record = catalog[result.settingID] {
                    await refresh(record)
                }
                switch result.kind {
                case .pendingLogout, .pendingRestart:
                    pendingRequirementIDs.insert(result.settingID)
                case .failedAndRolledBack, .failedWithoutRollback:
                    failedSettingIDs.insert(result.settingID)
                    rowStates[result.settingID]?.errorMessage = result.message
                default:
                    break
                }
            }
            onStateChange?()
        }
    }

    func rollbackLastApply() {
        guard let point = lastApplyReport?.rollbackPoint else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await applyCoordinator.rollback(point)
            for result in results {
                if let record = catalog[result.settingID] {
                    await refresh(record)
                }
            }
            onStateChange?()
        }
    }

    func undoMostRecentChange() async -> Bool {
        guard let change = history.first(where: \.canRollback),
              let record = catalog[change.settingID] else { return false }
        return await applyAndWait(change.previousValue, to: record)
    }

    func needsAttention(_ settingID: SystemSettingID) -> Bool {
        guard let state = rowStates[settingID] else { return false }
        if failedSettingIDs.contains(settingID) || pendingRequirementIDs.contains(settingID) {
            return true
        }
        switch state.availability {
        case .providerUnavailable, .hardwareUnavailable, .permissionMissing:
            return true
        case .available, .requiresLogout, .requiresRestart, .guidedManual, .managedOnly,
             .unsupported, .systemVersionUnsupported:
            return false
        }
    }

    private func persistFavorites() {
        storage.set(favoriteIDs.map(\.rawValue), forKey: StorageKey.favorites)
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    private func canRead(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart, .permissionMissing:
            true
        case .providerUnavailable, .hardwareUnavailable, .guidedManual,
             .managedOnly, .unsupported, .systemVersionUnsupported:
            false
        }
    }

    private func canApply(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart:
            true
        case .providerUnavailable, .hardwareUnavailable, .permissionMissing, .guidedManual,
             .managedOnly, .unsupported, .systemVersionUnsupported:
            false
        }
    }
}
