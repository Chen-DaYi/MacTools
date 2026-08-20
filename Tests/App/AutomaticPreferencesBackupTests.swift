import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class AutomaticPreferencesBackupTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        for suiteName in defaultsSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testAutomaticBackupsDefaultToEnabledAndPersistTheToggle() {
        let defaults = makeDefaults()
        let first = AutomaticPreferencesBackupCoordinator(userDefaults: defaults)

        XCTAssertTrue(first.isEnabled)
        first.setEnabled(false)

        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(
            AutomaticPreferencesBackupCoordinator(userDefaults: defaults).isEnabled
        )
    }

    func testStoreDeduplicatesSnapshotsThatOnlyDifferByExportDate() throws {
        let directory = makeTemporaryDirectoryURL()
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(30)

        XCTAssertCreated(try store.write(makeBackup(marker: "same", date: firstDate), now: firstDate))
        XCTAssertUnchanged(try store.write(makeBackup(marker: "same", date: secondDate), now: secondDate))

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        _ = try PreferencesBackup.decodeJSON(Data(contentsOf: files[0]))
    }

    func testStoreWritesChangedSnapshotsAtomicallyAndKeepsThemImportable() throws {
        let directory = makeTemporaryDirectoryURL()
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(10)

        XCTAssertCreated(try store.write(makeBackup(marker: "first", date: firstDate), now: firstDate))
        XCTAssertCreated(try store.write(makeBackup(marker: "second", date: secondDate), now: secondDate))

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, PreferencesBackup.maximumFileSize)
            _ = try PreferencesBackup.decodeJSON(data)
        }
    }

    func testGFSRetentionKeepsOneSnapshotPerOlderBucket() {
        let now = Date(timeIntervalSince1970: 1_704_110_400)
        let records = [
            record("recent-a", age: 5 * 60, now: now),
            record("recent-b", age: 45 * 60, now: now),
            record("hour-new", age: 2 * 60 * 60 + 5 * 60, now: now),
            record("hour-old", age: 2 * 60 * 60 + 45 * 60, now: now),
            record("hour-three", age: 3 * 60 * 60 + 5 * 60, now: now),
            record("day-new", age: 2 * 24 * 60 * 60, now: now),
            record("day-old", age: 2 * 24 * 60 * 60 + 60 * 60, now: now),
            record("day-three", age: 3 * 24 * 60 * 60, now: now),
            record("week-new", age: 40 * 24 * 60 * 60, now: now),
            record("week-old", age: 41 * 24 * 60 * 60, now: now),
            record("week-other", age: 50 * 24 * 60 * 60, now: now),
        ]

        let retainedNames = Set(
            AutomaticPreferencesBackupStore.retainedRecords(from: records, now: now)
                .map(\.url.lastPathComponent)
        )

        XCTAssertTrue(retainedNames.isSuperset(of: [
            "recent-a", "recent-b", "hour-new", "hour-three",
            "day-new", "day-three", "week-new", "week-other",
        ]))
        XCTAssertFalse(retainedNames.contains("hour-old"))
        XCTAssertFalse(retainedNames.contains("day-old"))
        XCTAssertFalse(retainedNames.contains("week-old"))
    }

    func testRetentionAppliesCountAndTotalSizeCapsToOldestSnapshots() {
        XCTAssertEqual(PreferencesBackup.maximumFileSize, 16 * 1024 * 1024)
        XCTAssertEqual(
            AutomaticPreferencesBackupStore.maximumTotalSize,
            128 * 1024 * 1024
        )

        let now = Date(timeIntervalSince1970: 1_704_110_400)
        let countRecords = (0 ..< 120).map { index in
            record("count-\(index)", age: TimeInterval(index), now: now, size: 1)
        }
        let countRetained = AutomaticPreferencesBackupStore.retainedRecords(
            from: countRecords,
            now: now
        )
        XCTAssertEqual(countRetained.count, 100)
        XCTAssertEqual(countRetained.first?.url.lastPathComponent, "count-0")
        XCTAssertEqual(countRetained.last?.url.lastPathComponent, "count-99")

        let largeRecords = (0 ..< 9).map { index in
            record(
                "large-\(index)",
                age: TimeInterval(index),
                now: now,
                size: PreferencesBackup.maximumFileSize
            )
        }
        let sizeRetained = AutomaticPreferencesBackupStore.retainedRecords(
            from: largeRecords,
            now: now
        )
        XCTAssertEqual(sizeRetained.count, 8)
        XCTAssertLessThanOrEqual(
            sizeRetained.reduce(0) { $0 + $1.size },
            AutomaticPreferencesBackupStore.maximumTotalSize
        )
    }

    func testCoordinatorDebouncesRepeatedPreferenceChanges() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        var marker = "first"
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: marker)
        }

        coordinator.persistentPreferencesDidChange()
        marker = "second"
        coordinator.persistentPreferencesDidChange()
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        let backup = try await PreferencesBackup.decodeJSON(contentsOf: files[0])
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["second"])
    }

    func testTerminationFlushesPendingSnapshot() throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .seconds(60)
        )
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: "termination")
        }

        coordinator.persistentPreferencesDidChange()
        coordinator.flushPendingBackupBeforeTermination()

        XCTAssertEqual(try backupFiles(in: directory).count, 1)
    }

    func testPluginPersistentPreferenceSignalSchedulesBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        let plugin = PersistentPreferenceSignalTestPlugin()
        let host = makeHost(
            defaults: defaults,
            coordinator: coordinator,
            plugins: [plugin]
        )

        plugin.updatePortablePreference("changed")
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginPreferences[plugin.metadata.id], Data("changed".utf8))
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testApplicationPreferencePersistenceSchedulesBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        defaults.set(
            AppAppearancePreference.dark.rawValue,
            forKey: AppAppearancePreference.userDefaultsKey
        )
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(
            backup.application.appearancePreference,
            AppAppearancePreference.dark.rawValue
        )
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testExcludedDefaultsChangesDoNotPostponeMeaningfulBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(50)
        )
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        defaults.set(
            AppAppearancePreference.dark.rawValue,
            forKey: AppAppearancePreference.userDefaultsKey
        )
        for index in 0 ..< 8 {
            try await Task.sleep(for: .milliseconds(10))
            defaults.set(index, forKey: "excluded.runtime.history")
        }
        try await Task.sleep(for: .milliseconds(20))

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        let backup = try await PreferencesBackup.decodeJSON(contentsOf: files[0])
        XCTAssertEqual(
            backup.application.appearancePreference,
            AppAppearancePreference.dark.rawValue
        )
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testImportCreatesImmediateSafetySnapshotBeforeOverwritingPreferences() throws {
        let defaults = makeDefaults()
        defaults.set(
            AppAppearancePreference.dark.rawValue,
            forKey: AppAppearancePreference.userDefaultsKey
        )
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .seconds(60)
        )
        coordinator.setEnabled(false)
        let host = makeHost(defaults: defaults, coordinator: coordinator)
        let imported = makeBackup(
            marker: "imported",
            appearance: .light
        )

        _ = try host.importPreferences(imported)

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        let safetyBackup = try PreferencesBackup.decodeJSON(Data(contentsOf: files[0]))
        XCTAssertEqual(
            safetyBackup.application.appearancePreference,
            AppAppearancePreference.dark.rawValue
        )
        XCTAssertEqual(
            AppAppearancePreference.stored(in: defaults),
            .light
        )
    }

    func testSafetySnapshotWriteFailurePreventsImportMutation() throws {
        let defaults = makeDefaults()
        defaults.set(
            AppAppearancePreference.dark.rawValue,
            forKey: AppAppearancePreference.userDefaultsKey
        )
        let invalidDirectory = makeTemporaryDirectoryURL()
        try Data("not a directory".utf8).write(to: invalidDirectory)
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: invalidDirectory)
        )
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        XCTAssertThrowsError(
            try host.importPreferences(makeBackup(marker: "imported", appearance: .light))
        )
        XCTAssertEqual(AppAppearancePreference.stored(in: defaults), .dark)
    }

    private func makeBackup(
        marker: String,
        date: Date = .now,
        appearance: AppAppearancePreference = .system
    ) -> PreferencesBackup {
        PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: appearance.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [marker],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            exportedAt: date
        )
    }

    private func makeHost(
        defaults: UserDefaults,
        coordinator: AutomaticPreferencesBackupCoordinator,
        plugins: [any MacToolsPlugin] = []
    ) -> PluginHost {
        PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            automaticPreferencesBackupCoordinator: coordinator,
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AutomaticPreferencesBackupTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticPreferencesBackupTests-\(UUID().uuidString)")
        temporaryURLs.append(url)
        return url
    }

    private func backupFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func record(
        _ name: String,
        age: TimeInterval,
        now: Date,
        size: Int = 1
    ) -> AutomaticPreferencesBackupRecord {
        AutomaticPreferencesBackupRecord(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            date: now.addingTimeInterval(-age),
            size: size
        )
    }

    private func XCTAssertCreated(
        _ result: AutomaticPreferencesBackupWriteResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .created = result else {
            return XCTFail("Expected a created backup, got \(result)", file: file, line: line)
        }
    }

    private func XCTAssertUnchanged(
        _ result: AutomaticPreferencesBackupWriteResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unchanged = result else {
            return XCTFail("Expected an unchanged backup, got \(result)", file: file, line: line)
        }
    }
}

@MainActor
private final class PersistentPreferenceSignalTestPlugin:
    MacToolsPlugin,
    PluginPortablePreferencesProviding,
    PluginPersistentPreferencesChangeSignaling
{
    let metadata = PluginMetadata(
        id: "persistent-signal-test",
        title: "Persistent Signal Test",
        iconName: "gearshape",
        iconTint: .blue,
        order: 0,
        defaultDescription: "Persistent Signal Test"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var onPersistentPreferencesChange: (() -> Void)?
    private var portablePreference = Data("initial".utf8)

    func makePortablePreferencesBackup() -> Data? {
        portablePreference
    }

    func restorePortablePreferences(from data: Data) {
        portablePreference = data
    }

    func updatePortablePreference(_ value: String) {
        portablePreference = Data(value.utf8)
        onPersistentPreferencesChange?()
    }
}
