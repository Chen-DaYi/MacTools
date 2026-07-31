import Foundation

// MARK: - Normalization result

/// Why a scan root was rejected. UI surfaces a concrete hint instead of silently dropping the folder just chosen.
enum DiskCleanPurgeRootRejection: Equatable, Sendable {
    /// Not an absolute path, or `realpath(3)` failed (missing, no permission, path too long).
    case unresolvable(path: String)
    /// Normalized form duplicates an existing root (e.g. different symlinks to the same directory).
    case duplicate(path: String)
    /// Covered by another root in the list: scanning an ancestor always covers descendants, so
    /// keeping the descendant would report the same candidates twice.
    case coveredByAncestor(path: String, ancestor: String)
    /// Home, system, or other top-level locations are too broad for developer-artifact discovery.
    case tooBroad(path: String)
}

/// Hard denylist for developer-artifact scan roots.
///
/// Purge discovery walks up to 6 levels and may default-select marker matches. Using Home,
/// `/Applications`, or other top-level locations as a root makes accidental mass selection too easy.
/// Project subfolders under Documents/Desktop remain allowed.
enum DiskCleanPurgeRootPolicy {
    /// Exact system / volume roots that must never be scan roots.
    private static let exactRestrictedRoots: Set<String> = [
        "/",
        "/Applications",
        "/System",
        "/Library",
        "/Users",
        "/home",
        "/Volumes",
        "/Network",
        "/private",
        "/var",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/opt",
        "/cores",
    ]

    /// Well-known top-level folders under the user’s home that are too broad as roots.
    private static let restrictedHomeFolderNames: Set<String> = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library",
        "Movies",
        "Music",
        "Pictures",
        "Public",
    ]

    /// `path` must already be a physical, trailing-slash-trimmed absolute path.
    static func isTooBroad(_ path: String) -> Bool {
        if exactRestrictedRoots.contains(path) {
            return true
        }

        let home = trimTrailingSlashes(NSHomeDirectory())
        if path == home {
            return true
        }
        if restrictedHomeFolderNames.contains(where: { path == home + "/" + $0 }) {
            return true
        }

        // Another user’s home (`/Users/name`) is equally too broad.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count == 2, components[0] == "Users" || components[0] == "home" {
            return true
        }

        return false
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

struct DiskCleanPurgeRootsUpdate: Equatable, Sendable {
    /// Normalized physical paths, preserving user add order.
    let roots: [String]
    let rejections: [DiskCleanPurgeRootRejection]
}

/// Scan-root normalization (design §10.1 + §13-6).
///
/// Three pure, side-effect-free jobs (`realpath` injected via `resolvePhysicalPath`):
/// 1. **Physical-path conversion**: paths fed to sizing / removal primitives must not contain
///    symlink ancestors, or `O_NOFOLLOW_ANY` rejects the whole tree with ELOOP (`/var` and `/tmp`
///    are themselves symlinks). Normalization must use `realpath(3)`.
/// 2. **Dedup**: two spellings may point at the same directory; only post-normalization shows that.
/// 3. **Ancestor adjudication—keep ancestor, drop descendant**: scanning both would report
///    descendant candidates twice; the reverse ("keep descendant, drop ancestor") would silently
///    shrink a scan range the user explicitly asked for. Adjudication looks at the full normalized
///    set only and is independent of add order: adding `~/Code/app` then `~/Code` still keeps only
///    `~/Code`.
enum DiskCleanPurgeRootNormalizer {
    static func normalize(
        _ paths: [String],
        resolvePhysicalPath: (String) -> String?
    ) -> DiskCleanPurgeRootsUpdate {
        var resolved: [(original: String, physical: String)] = []
        var rejections: [DiskCleanPurgeRootRejection] = []
        var seen: Set<String> = []

        for path in paths {
            let expanded = expandTilde(in: path)
            guard expanded.hasPrefix("/"), let physical = resolvePhysicalPath(expanded) else {
                rejections.append(.unresolvable(path: path))
                continue
            }
            let trimmed = trimTrailingSlashes(physical)
            if DiskCleanPurgeRootPolicy.isTooBroad(trimmed) {
                rejections.append(.tooBroad(path: path))
                continue
            }
            guard seen.insert(trimmed).inserted else {
                rejections.append(.duplicate(path: path))
                continue
            }
            resolved.append((original: path, physical: trimmed))
        }

        var roots: [String] = []
        for entry in resolved {
            if let ancestor = resolved.first(where: { isStrictAncestor($0.physical, of: entry.physical) }) {
                rejections.append(.coveredByAncestor(path: entry.original, ancestor: ancestor.physical))
                continue
            }
            roots.append(entry.physical)
        }

        return DiskCleanPurgeRootsUpdate(roots: roots, rejections: rejections)
    }

    /// Strict ancestor: `/a` is an ancestor of `/a/b`, but not of `/a` itself or of `/ab`.
    /// Both sides already have trailing slashes stripped; `/` is special-cased (join would yield `//`).
    static func isStrictAncestor(_ ancestor: String, of path: String) -> Bool {
        guard ancestor != path else { return false }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    private static func expandTilde(in path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst(1)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - Persistence seam

/// Raw persistence for scan roots. Same shape as `DiskCleanRemovalModeStoring`: store/load only, no semantics.
protocol DiskCleanPurgeRootsPersisting: Sendable {
    func loadRoots() -> [String]
    func saveRoots(_ roots: [String])
}

/// `UserDefaults` is thread-safe but not marked Sendable; same treatment as existing
/// `UserDefaultsDiskCleanRemovalModeStore`.
struct UserDefaultsDiskCleanPurgeRootsPersistence: DiskCleanPurgeRootsPersisting, @unchecked Sendable {
    static let defaultsKey = "DiskClean.purgeRoots"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRoots() -> [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func saveRoots(_ roots: [String]) {
        defaults.set(roots, forKey: Self.defaultsKey)
    }
}

// MARK: - Storage

/// User-configured developer-artifact scan roots (design §10.1). Empty by default—never whole-disk
/// scan; only directories the user explicitly names.
///
/// Writes always pass through `DiskCleanPurgeRootNormalizer`, so **stored paths are always physical**.
/// Reads drop denylisted roots but do not re-run `realpath`: a directory may have been deleted or
/// replaced, and a failed `realpath` would make a still-valid entry vanish. Letting the scanner
/// fail on `O_NOFOLLOW_ANY` open and report honestly is the more truthful degradation.
struct DiskCleanPurgeRootsStore: Sendable {
    private let persistence: any DiskCleanPurgeRootsPersisting
    private let resolvePhysicalPath: @Sendable (String) -> String?

    init(
        persistence: any DiskCleanPurgeRootsPersisting = UserDefaultsDiskCleanPurgeRootsPersistence(),
        resolvePhysicalPath: @escaping @Sendable (String) -> String? = { DiskCleanPhysicalPath.realpath(of: $0) }
    ) {
        self.persistence = persistence
        self.resolvePhysicalPath = resolvePhysicalPath
    }

    func roots() -> [String] {
        sanitizePersistedRoots()
    }

    /// Drop any persisted roots that are now denylisted, then return the allowed set.
    /// Keeps older installs / injected UserDefaults values from becoming scan roots.
    @discardableResult
    func sanitizePersistedRoots() -> [String] {
        let loaded = persistence.loadRoots()
        let allowed = loaded.filter { !DiskCleanPurgeRootPolicy.isTooBroad($0) }
        if allowed != loaded {
            persistence.saveRoots(allowed)
        }
        return allowed
    }

    /// Append a root and persist. Return value includes rejections for the UI to explain.
    @discardableResult
    func add(_ path: String) -> DiskCleanPurgeRootsUpdate {
        // Re-normalize only allowed existing roots so a newly rejected path does not surface
        // stale denylist noise for entries already removed by `sanitizePersistedRoots()`.
        replaceAll(with: sanitizePersistedRoots() + [path])
    }

    /// Remove a root. Match both the original spelling and the normalized form: if the directory
    /// no longer exists `realpath` fails, and matching only the normalized form would leave the
    /// user unable to delete the entry forever.
    @discardableResult
    func remove(_ path: String) -> [String] {
        let physical = resolvePhysicalPath(path)
        let remaining = persistence.loadRoots().filter { $0 != path && $0 != physical }
        persistence.saveRoots(remaining)
        return remaining
    }

    /// Replace the whole table (settings bulk edit, migrating old storage).
    @discardableResult
    func replaceAll(with paths: [String]) -> DiskCleanPurgeRootsUpdate {
        let update = DiskCleanPurgeRootNormalizer.normalize(paths, resolvePhysicalPath: resolvePhysicalPath)
        persistence.saveRoots(update.roots)
        return update
    }
}
