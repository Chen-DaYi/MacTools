import AppKit
import Foundation
import OSLog
import MacToolsPluginKit

// MARK: - ZshConfigStore

/// Manages zsh configuration file reads, edits, writes, and related file I/O.
@MainActor
final class ZshConfigStore: ObservableObject {

    // MARK: Published State

    @Published private(set) var selectedType: ZshConfigFileType = .zshrc
    @Published var editingContent: String = ""
    @Published private(set) var statusMap: [ZshConfigFileType: ZshFileStatus] = [:]
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var saveError: String? = nil
    @Published private(set) var hasUnsavedChanges: Bool = false
    @Published private(set) var lastSaveSucceeded: Bool = false

    // MARK: Private

    /// Last known on-disk content, updated after successful load or save to detect real edits.
    private var savedContent: String = ""
    private let localization: PluginLocalization

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "ZshConfigStore"
    )

    // MARK: Init

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        refreshStatusMap()
        loadFile(type: .zshrc)
    }

    // MARK: - Public API

    /// Switches to the file, loading its contents and discarding unsaved edits.
    func select(_ type: ZshConfigFileType) {
        guard type != selectedType else { return }
        selectedType = type
        saveError = nil
        lastSaveSucceeded = false
        loadFile(type: type)
    }

    /// Reloads the selected file from disk.
    func reloadCurrentFile() {
        loadFile(type: selectedType)
    }

    /// Saves `editingContent` to the selected file after creating a backup.
    func saveCurrentFile() {
        guard !isBusy else { return }
        save(type: selectedType, content: editingContent)
    }

    /// Creates the selected file from the default template when it does not exist.
    func createCurrentFile() {
        guard !isBusy else { return }
        createFile(type: selectedType)
    }

    /// Opens the file in the system default editor, creating it first if needed.
    func openInExternalEditor(_ type: ZshConfigFileType) {
        let url = type.fileURL
        if !(statusMap[type]?.exists ?? false) {
            createFile(type: type)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
        logger.info("Opened \(url.path) in external editor")
    }

    /// Reveals the file in Finder, or opens the home directory when the file does not exist.
    func revealInFinder(_ type: ZshConfigFileType) {
        let url = type.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// Appends a snippet to the end of `editingContent`.
    func appendSnippet(_ text: String) {
        if editingContent.isEmpty {
            editingContent = text
        } else if editingContent.hasSuffix("\n\n") {
            editingContent += text
        } else if editingContent.hasSuffix("\n") {
            editingContent += "\n" + text
        } else {
            editingContent += "\n\n" + text
        }
        hasUnsavedChanges = true
    }

    /// Refreshes status for every configuration file.
    func refreshStatusMap() {
        for type in ZshConfigFileType.allCases {
            statusMap[type] = ZshFileStatus.probe(type)
        }
    }

    /// Marks whether the current edit differs from the last saved content.
    func markEdited() {
        hasUnsavedChanges = editingContent != savedContent
        lastSaveSucceeded = false
    }

    // MARK: - Private

    private func loadFile(type: ZshConfigFileType) {
        saveError = nil
        hasUnsavedChanges = false
        lastSaveSucceeded = false
        let url = type.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            editingContent = ""
            return
        }
        do {
            editingContent = try String(contentsOf: url, encoding: .utf8)
            savedContent = editingContent
            let byteCount = editingContent.utf8.count
            logger.debug("Loaded \(url.path) (\(byteCount) bytes)")
        } catch {
            editingContent = ""
            savedContent = ""
            saveError = localization.format(
                "store.error.readFailed",
                defaultValue: "读取失败：%@",
                error.localizedDescription
            )
            logger.error("Failed to read \(url.path): \(error)")
        }
    }

    private func save(type: ZshConfigFileType, content: String) {
        isBusy = true
        saveError = nil
        lastSaveSucceeded = false
        let url = type.fileURL
        do {
            try makeBackupIfNeeded(url: url)
            try content.write(to: url, atomically: true, encoding: .utf8)
            savedContent = content
            hasUnsavedChanges = false
            lastSaveSucceeded = true
            refreshStatusMap()
            logger.info("Saved \(url.path)")
        } catch {
            saveError = localization.format(
                "store.error.saveFailed",
                defaultValue: "保存失败：%@",
                error.localizedDescription
            )
            logger.error("Failed to save \(url.path): \(error)")
        }
        isBusy = false
    }

    private func createFile(type: ZshConfigFileType) {
        let url = type.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        isBusy = true
        saveError = nil
        let header = buildFileHeader(for: type)
        do {
            try header.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Created \(url.path)")
            loadFile(type: type)
            refreshStatusMap()
        } catch {
            saveError = localization.format(
                "store.error.createFailed",
                defaultValue: "创建失败：%@",
                error.localizedDescription
            )
            logger.error("Failed to create \(url.path): \(error)")
        }
        isBusy = false
    }

    /// Creates a backup before each save, replacing the previous `.bak` backup.
    private func makeBackupIfNeeded(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".bak")
        let fm = FileManager.default
        if fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: backupURL)
        }
        try fm.copyItem(at: url, to: backupURL)
        logger.debug("Backed up \(url.lastPathComponent) → \(backupURL.lastPathComponent)")
    }

    private func buildFileHeader(for type: ZshConfigFileType) -> String {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let sourceCommand = "source \(type.filename)"
        return """
        # \(type.filename)
        # \(localization.format("store.header.role", defaultValue: "说明：%@", type.role(localization: localization)))
        # \(localization.format("store.header.whenLoaded", defaultValue: "加载时机：%@", type.whenLoaded(localization: localization)))
        # \(localization.format("store.header.recommendedUse", defaultValue: "推荐用途：%@", type.recommendedUse(localization: localization)))
        # \(localization.format("store.header.createdAt", defaultValue: "由 MacTools 创建于 %@", createdAt))
        #
        # \(localization.format("store.header.reloadHint", defaultValue: "保存后，在终端执行 %@ 即可立即生效（.zshrc 适用）。", sourceCommand))
        #

        """
    }
}
