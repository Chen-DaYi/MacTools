import AppKit

protocol QuitAppRunningApplication: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var bundleIdentifier: String? { get }
    var localizedName: String? { get }
    var icon: NSImage? { get }
    var isTerminated: Bool { get }

    @discardableResult
    func terminate() -> Bool
}

extension NSRunningApplication: QuitAppRunningApplication {}

struct QuitAppInstanceSnapshot {
    let bundleIdentifier: String
    let application: any QuitAppRunningApplication
    let displayName: String?
    let icon: NSImage?

    init?(
        application: any QuitAppRunningApplication,
        excludingBundleIdentifier: String?
    ) {
        guard let bundleIdentifier = QuitAppsApplicationCatalog.eligibleBundleIdentifier(
            for: application,
            excludingBundleIdentifier: excludingBundleIdentifier
        )
        else {
            return nil
        }

        let normalizedName = application.localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.bundleIdentifier = bundleIdentifier
        self.application = application
        self.displayName = normalizedName?.isEmpty == false ? normalizedName : nil
        self.icon = application.icon
    }
}

struct QuitAppGroup {
    let id: String
    let displayName: String
    let icon: NSImage?
    let applications: [any QuitAppRunningApplication]
}

enum QuitAppsApplicationCatalog {
    @MainActor
    static func currentApplicationCount(
        excludingBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Int {
        let applications = NSWorkspace.shared.runningApplications.map {
            $0 as any QuitAppRunningApplication
        }
        return applicationCount(
            from: applications,
            excludingBundleIdentifier: excludingBundleIdentifier
        )
    }

    @MainActor
    static func currentGroups(
        excludingBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [QuitAppGroup] {
        let applications = NSWorkspace.shared.runningApplications.map {
            $0 as any QuitAppRunningApplication
        }
        return groups(
            from: applications,
            excludingBundleIdentifier: excludingBundleIdentifier
        )
    }

    static func applicationCount(
        from applications: [any QuitAppRunningApplication],
        excludingBundleIdentifier: String?
    ) -> Int {
        Set(applications.compactMap {
            eligibleBundleIdentifier(
                for: $0,
                excludingBundleIdentifier: excludingBundleIdentifier
            )
        }).count
    }

    static func eligibleBundleIdentifier(
        for application: any QuitAppRunningApplication,
        excludingBundleIdentifier: String?
    ) -> String? {
        guard application.activationPolicy == .regular,
              !application.isTerminated,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier != excludingBundleIdentifier
        else {
            return nil
        }

        return bundleIdentifier
    }

    static func groups(
        from applications: [any QuitAppRunningApplication],
        excludingBundleIdentifier: String?
    ) -> [QuitAppGroup] {
        let snapshots = applications.compactMap {
            QuitAppInstanceSnapshot(
                application: $0,
                excludingBundleIdentifier: excludingBundleIdentifier
            )
        }
        return groups(from: snapshots)
    }

    static func groups(from snapshots: [QuitAppInstanceSnapshot]) -> [QuitAppGroup] {
        Dictionary(grouping: snapshots, by: \.bundleIdentifier)
            .map { bundleIdentifier, instances in
                var seenApplications = Set<ObjectIdentifier>()
                let applications = instances.compactMap { instance in
                    let identifier = ObjectIdentifier(instance.application)
                    return seenApplications.insert(identifier).inserted
                        ? instance.application
                        : nil
                }

                return QuitAppGroup(
                    id: bundleIdentifier,
                    displayName: instances.compactMap(\.displayName).first ?? bundleIdentifier,
                    icon: instances.compactMap(\.icon).first,
                    applications: applications
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }
}
