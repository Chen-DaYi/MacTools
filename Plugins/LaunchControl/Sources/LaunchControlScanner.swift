import Foundation
import MacToolsPluginKit

struct LaunchControlScanResult: Sendable {
    let items: [LaunchControlItem]
    let warnings: [String]
}

struct LaunchControlScanner: @unchecked Sendable {
    private struct LaunchDirectory: Sendable {
        let url: URL
        let scope: LaunchControlScope
        let domain: String
    }

    private let fileManager: FileManager
    private let runner: any LaunchControlCommandRunning
    private let userIDProvider: @Sendable () -> uid_t
    private let localization: PluginLocalization

    init(
        fileManager: FileManager = .default,
        runner: any LaunchControlCommandRunning = ProcessLaunchControlCommandRunner(),
        userIDProvider: @escaping @Sendable () -> uid_t = { getuid() },
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.fileManager = fileManager
        self.runner = runner
        self.userIDProvider = userIDProvider
        self.localization = localization
    }

    func scan(progress: @escaping @Sendable (LaunchControlScanEvent) -> Void = { _ in }) -> LaunchControlScanResult {
        let userID = userIDProvider()
        let userDomain = "gui/\(userID)"
        let directories = launchDirectories(userDomain: userDomain)
        var warnings: [String] = []
        progress(.message(localization.string("scanner.progress.disabledState", defaultValue: "读取 launchctl 禁用状态")))
        let disabledLabelsByDomain = loadDisabledLabels(domains: Set(directories.map(\.domain)))
        // Fetch the whole user GUI domain in ONE `launchctl list` instead of one
        // `launchctl print gui/<uid>/<label>` per item — the Status column is the
        // last exit status and the PID column the running pid, so the data is
        // equivalent. System-domain daemons are unaffected (handled per item below).
        progress(.message(localization.string("scanner.progress.runningState", defaultValue: "读取 launchctl 运行状态")))
        let userDomainStatuses = Self.parseLaunchctlList(
            (try? runner.runLaunchctl(arguments: ["list"]))?.combinedOutput ?? ""
        )
        var items: [LaunchControlItem] = []

        for directory in directories {
            progress(.directory(directory.url.path))
            guard let plistURLs = try? fileManager.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                progress(.message(localization.format(
                    "scanner.progress.skipUnreadableDirectory",
                    defaultValue: "跳过不可读取目录：%@",
                    directory.url.path
                )))
                continue
            }

            for plistURL in plistURLs where plistURL.pathExtension == "plist" {
                progress(.file(plistURL.path))
                do {
                    let summary = try Self.parsePlist(at: plistURL, localization: localization)
                    let label = summary.label.isEmpty
                        ? plistURL.deletingPathExtension().lastPathComponent
                        : summary.label
                    let disabledLabels = disabledLabelsByDomain[directory.domain, default: []]
                    let launchctlStatus: (exitCode: Int32, pid: Int?, lastExitStatus: Int?)
                    if directory.scope == .system {
                        launchctlStatus = (exitCode: Int32(-2), pid: nil, lastExitStatus: nil)
                    } else if directory.domain == userDomain {
                        // User GUI domain: served by the single `launchctl list` above.
                        launchctlStatus = Self.status(from: userDomainStatuses, label: label)
                    } else {
                        // System-domain daemons (e.g. /Library/LaunchDaemons): unchanged.
                        launchctlStatus = loadLaunchctlStatus(domain: directory.domain, label: label)
                    }
                    let isDisabled = disabledLabels.contains(label)
                    let state = Self.state(
                        isDisabled: isDisabled,
                        printExitCode: launchctlStatus.exitCode,
                        pid: launchctlStatus.pid,
                        lastExitStatus: launchctlStatus.lastExitStatus
                    )

                    let item = LaunchControlItem(
                        id: plistURL.path,
                        label: label,
                        plistURL: plistURL,
                        scope: directory.scope,
                            origin: Self.origin(
                                for: plistURL,
                                scope: directory.scope,
                                label: label,
                                summary: summary,
                                homeDirectory: fileManager.homeDirectoryForCurrentUser
                            ),
                        state: state,
                        pid: launchctlStatus.pid,
                        lastExitStatus: launchctlStatus.lastExitStatus,
                        programArguments: summary.programArguments,
                        runAtLoad: summary.runAtLoad,
                        keepAliveDescription: summary.keepAliveDescription,
                        startInterval: summary.startInterval,
                        startCalendarDescription: summary.startCalendarDescription,
                        rawPlist: summary.rawPlist,
                        launchctlDomain: directory.domain,
                        isDisabled: isDisabled,
                        isLoaded: launchctlStatus.exitCode == 0,
                        isFavorite: false
                    )
                    items.append(item)
                    progress(.found(item))
                } catch {
                    warnings.append("\(plistURL.path): \(error.localizedDescription)")
                    progress(.message(localization.format(
                        "scanner.progress.parseFailed",
                        defaultValue: "解析失败：%@",
                        plistURL.lastPathComponent
                    )))
                }
            }
        }

        return LaunchControlScanResult(
            items: items.sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite {
                    return lhs.isFavorite
                }
                if lhs.origin != rhs.origin {
                    return lhs.origin.rawValue < rhs.origin.rawValue
                }
                if lhs.scope != rhs.scope {
                    return lhs.scope.rawValue < rhs.scope.rawValue
                }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            },
            warnings: warnings
        )
    }

    static func parsePlist(
        at url: URL,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) throws -> LaunchControlPlistSummary {
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = propertyList as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let rawPlist = String(data: data, encoding: .utf8) ?? NSString(data: data, encoding: String.Encoding.utf8.rawValue).map(String.init) ?? ""
        let label = dictionary["Label"] as? String ?? ""
        let programArguments = dictionary["ProgramArguments"] as? [String]
            ?? (dictionary["Program"] as? String).map { [$0] }
            ?? []

        return LaunchControlPlistSummary(
            label: label,
            programArguments: programArguments,
            runAtLoad: dictionary["RunAtLoad"] as? Bool ?? false,
            keepAliveDescription: describe(dictionary["KeepAlive"], localization: localization),
            startInterval: dictionary["StartInterval"] as? Int,
            startCalendarDescription: describeStartCalendar(dictionary["StartCalendarInterval"]),
            rawPlist: rawPlist
        )
    }

    static func parseLaunchctlPrint(_ output: String) -> (pid: Int?, lastExitStatus: Int?) {
        var pid: Int?
        var lastExitStatus: Int?

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid =") {
                pid = Int(trimmed.replacingOccurrences(of: "pid =", with: "").trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("last exit code =") {
                lastExitStatus = Int(trimmed.replacingOccurrences(of: "last exit code =", with: "").trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("last exit status =") {
                lastExitStatus = Int(trimmed.replacingOccurrences(of: "last exit status =", with: "").trimmingCharacters(in: .whitespaces))
            }
        }

        return (pid, lastExitStatus)
    }

    static func parseDisabledLabels(_ output: String) -> Set<String> {
        var labels = Set<String>()
        let scanner = Scanner(string: output)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines

        while !scanner.isAtEnd {
            _ = scanner.scanUpToString("\"")
            guard scanner.scanString("\"") != nil,
                  let label = scanner.scanUpToString("\""),
                  scanner.scanString("\"") != nil
            else {
                break
            }
            _ = scanner.scanUpToString("=>")
            _ = scanner.scanString("=>")
            // Modern macOS (14+) emits `=> disabled` / `=> enabled`; older output
            // used `=> true` / `=> false`. Accept both so disabled items are
            // detected on current systems (the previous code only matched "true",
            // so on shipping macOS the disabled set was always empty).
            if scanner.scanString("disabled") != nil || scanner.scanString("true") != nil {
                labels.insert(label)
            } else {
                _ = scanner.scanUpToCharacters(from: .newlines)
            }
        }

        return labels
    }

    private func launchDirectories(userDomain: String) -> [LaunchDirectory] {
        [
            LaunchDirectory(
                url: fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                scope: .user,
                domain: userDomain
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                scope: .global,
                domain: userDomain
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                scope: .global,
                domain: "system"
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/System/Library/LaunchAgents", isDirectory: true),
                scope: .system,
                domain: userDomain
            ),
            LaunchDirectory(
                url: URL(fileURLWithPath: "/System/Library/LaunchDaemons", isDirectory: true),
                scope: .system,
                domain: "system"
            )
        ]
    }

    private func loadDisabledLabels(domains: Set<String>) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: domains.map { domain in
            let result = try? runner.runLaunchctl(arguments: ["print-disabled", domain])
            return (domain, Self.parseDisabledLabels(result?.combinedOutput ?? ""))
        })
    }

    /// Parses `launchctl list` output (tab-separated `PID  Status  Label`, with a
    /// header row) into a label → (pid, lastExitStatus) map. `-` becomes nil.
    static func parseLaunchctlList(_ output: String) -> [String: (pid: Int?, lastExitStatus: Int?)] {
        var result: [String: (pid: Int?, lastExitStatus: Int?)] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label != "Label" else { continue } // skip header / blanks
            result[label] = (
                pid: Int(columns[0].trimmingCharacters(in: .whitespaces)),
                lastExitStatus: Int(columns[1].trimmingCharacters(in: .whitespaces))
            )
        }
        return result
    }

    /// Maps a `launchctl list` entry to the same status tuple shape the per-item
    /// `launchctl print` path produces: present → loaded (exitCode 0); absent →
    /// not loaded (exitCode 1), matching a non-zero `launchctl print`.
    static func status(
        from map: [String: (pid: Int?, lastExitStatus: Int?)],
        label: String
    ) -> (exitCode: Int32, pid: Int?, lastExitStatus: Int?) {
        guard let entry = map[label] else {
            return (exitCode: 1, pid: nil, lastExitStatus: nil)
        }
        return (exitCode: 0, pid: entry.pid, lastExitStatus: entry.lastExitStatus)
    }

    private func loadLaunchctlStatus(domain: String, label: String) -> (exitCode: Int32, pid: Int?, lastExitStatus: Int?) {
        guard !label.isEmpty else {
            return (1, nil, nil)
        }

        do {
            let result = try runner.runLaunchctl(arguments: ["print", "\(domain)/\(label)"])
            let parsed = Self.parseLaunchctlPrint(result.combinedOutput)
            return (result.exitCode, parsed.pid, parsed.lastExitStatus)
        } catch {
            return (1, nil, nil)
        }
    }

    private static func state(
        isDisabled: Bool,
        printExitCode: Int32,
        pid: Int?,
        lastExitStatus: Int?
    ) -> LaunchControlState {
        if isDisabled {
            return .disabled
        }
        if let pid, pid > 0 {
            return .running
        }
        if let lastExitStatus, lastExitStatus != 0 {
            return .failed
        }
        if printExitCode == -2 {
            return .unknown
        }
        if printExitCode == 0 {
            return .loaded
        }
        return .unloaded
    }

    private static func origin(
        for url: URL,
        scope: LaunchControlScope,
        label: String,
        summary: LaunchControlPlistSummary,
        homeDirectory: URL
    ) -> LaunchControlOrigin {
        if scope == .system || url.path.hasPrefix("/System/") || label.hasPrefix("com.apple.") {
            return .system
        }
        if scope == .user {
            let path = url.path
            if path.contains("/Library/LaunchAgents/") && !label.hasPrefix("com.") {
                return .userCreated
            }
            if label.hasPrefix("local.") || label.hasPrefix("homebrew.") {
                return .userCreated
            }
            if looksLikeUserAuthoredCommand(summary.programArguments, homeDirectory: homeDirectory) {
                return .userCreated
            }
        }
        return .thirdParty
    }

    private static func looksLikeUserAuthoredCommand(
        _ arguments: [String],
        homeDirectory: URL
    ) -> Bool {
        let commandText = arguments.joined(separator: " ")
        let homePath = homeDirectory.path
        let userToolMarkers = [
            "/bin/sh",
            "/bin/zsh",
            "/bin/bash",
            "/opt/homebrew/",
            "/usr/local/",
            "\(homePath)/",
            " npx ",
            " node ",
            " python",
            " ruby",
            " bun ",
            " deno "
        ]

        return userToolMarkers.contains { marker in
            commandText.localizedCaseInsensitiveContains(marker)
        }
    }

    private static func describe(
        _ value: Any?,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String? {
        switch value {
        case let bool as Bool:
            return bool ? localization.string("scanner.keepAlive.always", defaultValue: "持续保活") : nil
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted()
            return keys.isEmpty
                ? localization.string("scanner.keepAlive.custom", defaultValue: "自定义条件")
                : keys.joined(separator: ", ")
        case let string as String:
            return string
        case .some:
            return localization.string("scanner.keepAlive.custom", defaultValue: "自定义条件")
        case .none:
            return nil
        }
    }

    private static func describeStartCalendar(_ value: Any?) -> String? {
        if let dictionary = value as? [String: Any] {
            return dictionary
                .keys
                .sorted()
                .compactMap { key in
                    guard let value = dictionary[key] else { return nil }
                    return "\(key)=\(value)"
                }
                .joined(separator: ", ")
        }

        if let dictionaries = value as? [[String: Any]] {
            return dictionaries
                .map { dictionary in
                    dictionary
                        .keys
                        .sorted()
                        .compactMap { key in
                            guard let value = dictionary[key] else { return nil }
                            return "\(key)=\(value)"
                        }
                        .joined(separator: ", ")
                }
                .joined(separator: "；")
        }

        return nil
    }
}
