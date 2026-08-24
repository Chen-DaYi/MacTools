import Foundation

enum SystemSettingsProfilePlanStatus: Equatable, Sendable {
    case ready
    case alreadyMatches
    case requiresLogout
    case requiresRestart
    case guidedManual
    case unsupported(String)
    case unavailable(String)
    case verificationUnavailable
    case invalidValue
    case unknownSetting

    var canSelect: Bool {
        switch self {
        case .ready, .requiresLogout, .requiresRestart, .verificationUnavailable:
            true
        case .alreadyMatches, .guidedManual, .unsupported, .unavailable, .invalidValue, .unknownSetting:
            false
        }
    }
}

struct SystemSettingsProfilePlanItem: Identifiable, Equatable, Sendable {
    let settingID: SystemSettingID
    let title: String
    let currentValue: SystemSettingValue?
    let desiredValue: SystemSettingValue
    let status: SystemSettingsProfilePlanStatus
    let isSelected: Bool

    var id: SystemSettingID { settingID }

    func selecting(_ selected: Bool) -> Self {
        Self(
            settingID: settingID,
            title: title,
            currentValue: currentValue,
            desiredValue: desiredValue,
            status: status,
            isSelected: status.canSelect && selected
        )
    }
}

struct SystemSettingsProfileApplyPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileID: UUID
    let profileName: String
    let createdAt: Date
    let items: [SystemSettingsProfilePlanItem]

    init(
        id: UUID = UUID(),
        profileID: UUID,
        profileName: String,
        createdAt: Date = Date(),
        items: [SystemSettingsProfilePlanItem]
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.createdAt = createdAt
        self.items = items
    }

    func selecting(_ selectedIDs: Set<SystemSettingID>) -> Self {
        Self(
            id: id,
            profileID: profileID,
            profileName: profileName,
            createdAt: createdAt,
            items: items.map { $0.selecting(selectedIDs.contains($0.settingID)) }
        )
    }
}

@MainActor
enum SystemSettingsProfilePlanner {
    static func makePlan(
        profile: SystemSettingsProfile,
        catalog: SystemSettingCatalog,
        currentValues: [SystemSettingID: SystemSettingValue],
        availability: [SystemSettingID: SystemSettingAvailability],
        date: Date = Date()
    ) -> SystemSettingsProfileApplyPlan {
        let items = profile.entries.map { entry -> SystemSettingsProfilePlanItem in
            guard let record = catalog[entry.settingID] else {
                return .init(
                    settingID: entry.settingID,
                    title: entry.settingID.rawValue,
                    currentValue: nil,
                    desiredValue: entry.desiredValue,
                    status: .unknownSetting,
                    isSelected: false
                )
            }
            let definition = record.definition
            guard definition.schema.accepts(entry.desiredValue) else {
                return item(record, entry, currentValues, .invalidValue, selected: false)
            }
            let current = currentValues[entry.settingID]
            if current == entry.desiredValue {
                return item(record, entry, currentValues, .alreadyMatches, selected: false)
            }
            let status: SystemSettingsProfilePlanStatus
            switch availability[entry.settingID] ?? .available {
            case .available:
                status = definition.verificationAvailable ? .ready : .verificationUnavailable
            case .requiresLogout:
                status = .requiresLogout
            case .requiresRestart:
                status = .requiresRestart
            case let .providerUnavailable(providerID):
                status = .unavailable("缺少插件：\(providerID)")
            case let .hardwareUnavailable(hardware):
                status = .unavailable("缺少硬件：\(hardware)")
            case let .permissionMissing(permission):
                status = .unavailable("缺少权限：\(permission)")
            case .guidedManual:
                status = .guidedManual
            case .managedOnly:
                status = .unsupported("此设置只能由组织管理。")
            case let .unsupported(reason):
                status = .unsupported(reason)
            case .systemVersionUnsupported:
                status = .unavailable("当前 macOS 版本不受支持。")
            }
            return item(record, entry, currentValues, status, selected: status.canSelect)
        }
        return .init(
            profileID: profile.id,
            profileName: profile.name,
            createdAt: date,
            items: items
        )
    }

    private static func item(
        _ record: SystemSettingRecord,
        _ entry: SystemSettingsProfileEntry,
        _ currentValues: [SystemSettingID: SystemSettingValue],
        _ status: SystemSettingsProfilePlanStatus,
        selected: Bool
    ) -> SystemSettingsProfilePlanItem {
        .init(
            settingID: entry.settingID,
            title: record.definition.title,
            currentValue: currentValues[entry.settingID],
            desiredValue: entry.desiredValue,
            status: status,
            isSelected: selected
        )
    }
}

enum SystemSettingsProfileApplyResultKind: String, Codable, Sendable {
    case appliedAndVerified
    case alreadyMatched
    case pendingLogout
    case pendingRestart
    case skippedByUser
    case guidedManual
    case unsupported
    case providerUnavailable
    case failedAndRolledBack
    case failedWithoutRollback
    case verificationUnavailable
}

struct SystemSettingsProfileApplyResult: Identifiable, Equatable, Sendable {
    let settingID: SystemSettingID
    let title: String
    let kind: SystemSettingsProfileApplyResultKind
    let message: String?

    var id: SystemSettingID { settingID }
}

struct SystemSettingRollbackSnapshotEntry: Codable, Equatable, Sendable {
    let settingID: SystemSettingID
    let value: SystemSettingValue
}

struct SystemSettingRollbackPoint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let profileID: UUID
    let entries: [SystemSettingRollbackSnapshotEntry]
}

struct SystemSettingsProfileApplyReport: Identifiable, Equatable, Sendable {
    let id: UUID
    let planID: UUID
    let completedAt: Date
    let results: [SystemSettingsProfileApplyResult]
    let rollbackPoint: SystemSettingRollbackPoint

    var hasPartialSuccess: Bool {
        let kinds = Set(results.map(\.kind))
        let successKinds: Set<SystemSettingsProfileApplyResultKind> = [
            .appliedAndVerified, .alreadyMatched, .pendingLogout, .pendingRestart,
        ]
        return !kinds.isSubset(of: successKinds)
    }
}

@MainActor
final class SystemSettingsProfileApplyCoordinator {
    private let catalog: SystemSettingCatalog

    init(catalog: SystemSettingCatalog) {
        self.catalog = catalog
    }

    func apply(
        plan: SystemSettingsProfileApplyPlan,
        date: Date = Date()
    ) async -> SystemSettingsProfileApplyReport {
        let rollbackEntries = plan.items.compactMap { item -> SystemSettingRollbackSnapshotEntry? in
            guard item.isSelected,
                  let record = catalog[item.settingID],
                  record.definition.canRollback,
                  let currentValue = item.currentValue else { return nil }
            return .init(settingID: item.settingID, value: currentValue)
        }
        let rollbackPoint = SystemSettingRollbackPoint(
            id: UUID(),
            createdAt: date,
            profileID: plan.profileID,
            entries: rollbackEntries
        )
        var results: [SystemSettingsProfileApplyResult] = []
        for item in plan.items {
            results.append(await apply(item: item))
        }
        return .init(
            id: UUID(),
            planID: plan.id,
            completedAt: date,
            results: results,
            rollbackPoint: rollbackPoint
        )
    }

    func rollback(
        _ point: SystemSettingRollbackPoint
    ) async -> [SystemSettingsProfileApplyResult] {
        var results: [SystemSettingsProfileApplyResult] = []
        for entry in point.entries.reversed() {
            guard let record = catalog[entry.settingID] else { continue }
            do {
                try await record.adapter.rollback(to: entry.value)
                let verification = try await record.adapter.verify(entry.value)
                let succeeded: Bool
                if case .verified = verification { succeeded = true } else { succeeded = false }
                results.append(.init(
                    settingID: entry.settingID,
                    title: record.definition.title,
                    kind: succeeded ? .appliedAndVerified : .failedWithoutRollback,
                    message: succeeded ? nil : "回滚验证失败。"
                ))
            } catch {
                results.append(.init(
                    settingID: entry.settingID,
                    title: record.definition.title,
                    kind: .failedWithoutRollback,
                    message: error.localizedDescription
                ))
            }
        }
        return results
    }

    private func apply(
        item: SystemSettingsProfilePlanItem
    ) async -> SystemSettingsProfileApplyResult {
        guard item.isSelected else {
            let kind: SystemSettingsProfileApplyResultKind = switch item.status {
            case .alreadyMatches: .alreadyMatched
            case .guidedManual: .guidedManual
            case .unsupported, .invalidValue, .unknownSetting: .unsupported
            case .unavailable: .providerUnavailable
            default: .skippedByUser
            }
            return .init(settingID: item.settingID, title: item.title, kind: kind, message: nil)
        }
        guard let record = catalog[item.settingID] else {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .unsupported,
                message: "未知设置不会被执行。"
            )
        }
        do {
            try await record.adapter.apply(item.desiredValue)
            let verification = try await record.adapter.verify(item.desiredValue)
            switch verification {
            case .verified:
                let kind: SystemSettingsProfileApplyResultKind = switch item.status {
                case .requiresLogout: .pendingLogout
                case .requiresRestart: .pendingRestart
                default: .appliedAndVerified
                }
                return .init(settingID: item.settingID, title: item.title, kind: kind, message: nil)
            case .unavailable:
                return .init(
                    settingID: item.settingID,
                    title: item.title,
                    kind: .verificationUnavailable,
                    message: "已写入，但无法验证当前值。"
                )
            case let .mismatch(actual):
                return await rollbackAfterFailure(
                    record: record,
                    item: item,
                    message: "验证结果为 \(actual.conciseDescription)。"
                )
            }
        } catch {
            return await rollbackAfterFailure(
                record: record,
                item: item,
                message: error.localizedDescription
            )
        }
    }

    private func rollbackAfterFailure(
        record: SystemSettingRecord,
        item: SystemSettingsProfilePlanItem,
        message: String
    ) async -> SystemSettingsProfileApplyResult {
        guard record.definition.canRollback, let current = item.currentValue else {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .failedWithoutRollback,
                message: message
            )
        }
        do {
            try await record.adapter.rollback(to: current)
            let verification = try await record.adapter.verify(current)
            guard case .verified = verification else {
                return .init(
                    settingID: item.settingID,
                    title: item.title,
                    kind: .failedWithoutRollback,
                    message: "\(message) 回滚验证失败。"
                )
            }
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .failedAndRolledBack,
                message: message
            )
        } catch {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .failedWithoutRollback,
                message: "\(message) 回滚失败：\(error.localizedDescription)"
            )
        }
    }
}
