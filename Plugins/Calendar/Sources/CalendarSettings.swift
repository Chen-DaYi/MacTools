import Combine
import Foundation
import SwiftUI
import MacToolsPluginKit

enum CalendarWeekStartDay: String, CaseIterable, Identifiable, Sendable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: String { rawValue }

    var calendarFirstWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }

    func displayName(locale: Locale = PluginRuntimeLocalization.locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        let index = calendarFirstWeekday - 1
        return formatter.weekdaySymbols.indices.contains(index)
            ? formatter.weekdaySymbols[index]
            : rawValue
    }
}

@MainActor
final class CalendarSettingsStore: ObservableObject {
    private enum StorageKey {
        static let weekStartDay = "settings.week-start-day"
    }

    @Published private(set) var weekStartDay: CalendarWeekStartDay

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
        self.weekStartDay = storage.string(forKey: StorageKey.weekStartDay)
            .flatMap(CalendarWeekStartDay.init(rawValue:))
            ?? .sunday
    }

    func setWeekStartDay(_ day: CalendarWeekStartDay) {
        guard weekStartDay != day else {
            return
        }

        weekStartDay = day
        storage.set(day.rawValue, forKey: StorageKey.weekStartDay)
    }
}

struct CalendarSettingsView: View {
    @ObservedObject var store: CalendarSettingsStore

    let localization: PluginLocalization
    let onWeekStartDayChange: (CalendarWeekStartDay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string("settings.display.title", defaultValue: "日历显示"),
                systemImage: "calendar"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(localization.string("settings.weekStart.title", defaultValue: "每周起始日"))
                        .font(PluginSettingsTheme.Typography.rowTitle)

                    Text(localization.string(
                        "settings.weekStart.description",
                        defaultValue: "选择月历每周显示的第一天。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Picker(
                    localization.string("settings.weekStart.title", defaultValue: "每周起始日"),
                    selection: weekStartDayBinding
                ) {
                    ForEach(CalendarWeekStartDay.allCases) { day in
                        Text(day.displayName())
                            .tag(day)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(minWidth: 110, idealWidth: 130, maxWidth: 160)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
            .pluginSettingsCardBackground(.host)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var weekStartDayBinding: Binding<CalendarWeekStartDay> {
        Binding(
            get: { store.weekStartDay },
            set: { day in
                onWeekStartDayChange(day)
            }
        )
    }
}
