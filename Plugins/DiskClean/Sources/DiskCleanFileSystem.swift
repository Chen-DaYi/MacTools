import Darwin
import Foundation

struct DiskCleanFileItem: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let resolvedSymlinkTarget: String?
}

protocol DiskCleanFileSystemProviding: Sendable {
    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem]
    func itemInfo(at path: String) throws -> DiskCleanFileItem?
    /// 直接子项（**含隐藏项**）。祖先分解（设计 §5.3）用它，因此绝不能用 `*` glob 代替——
    /// glob 会漏掉点开头的条目，分解后就少了一块，等于悄悄缩小扫描范围。
    func directChildren(of path: String) throws -> [DiskCleanFileItem]
    func removeItem(at path: String) throws
    func deduplicatedParentChildPaths(_ paths: [String]) -> [String]
}

struct LocalDiskCleanFileSystem: DiskCleanFileSystemProviding, @unchecked Sendable {
    private let fileManager: FileManager
    private let homeDirectory: String

    init(
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.fileManager = fileManager
        self.homeDirectory = Self.normalizeSlashes(homeDirectory)
    }

    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem] {
        let expandedPattern = Self.normalizeSlashes(expandHome(in: pattern))
        guard Self.containsGlob(expandedPattern) else {
            guard let item = try itemInfo(at: expandedPattern) else { return [] }
            return [item]
        }

        let matchedPaths = try Self.globPaths(matching: expandedPattern)
        return try deduplicatedParentChildPaths(matchedPaths)
            .compactMap { try itemInfo(at: $0) }
    }

    func itemInfo(at path: String) throws -> DiskCleanFileItem? {
        let expandedPath = Self.normalizeSlashes(expandHome(in: path))
        guard fileManager.fileExists(atPath: expandedPath) || isSymlink(at: expandedPath) else {
            return nil
        }

        let attributes = try fileManager.attributesOfItem(atPath: expandedPath)
        let fileType = attributes[.type] as? FileAttributeType
        let isSymlink = fileType == .typeSymbolicLink
        let isDirectory = fileType == .typeDirectory

        return DiskCleanFileItem(
            path: expandedPath,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            resolvedSymlinkTarget: isSymlink ? try? fileManager.destinationOfSymbolicLink(atPath: expandedPath) : nil
        )
    }

    func directChildren(of path: String) throws -> [DiskCleanFileItem] {
        let expandedPath = Self.normalizeSlashes(expandHome(in: path))
        let names = try fileManager.contentsOfDirectory(atPath: expandedPath)
        return names.sorted().compactMap { name in
            try? itemInfo(at: expandedPath + "/" + name)
        }
    }

    func removeItem(at path: String) throws {
        let expandedPath = Self.normalizeSlashes(expandHome(in: path))
        guard fileManager.fileExists(atPath: expandedPath) || isSymlink(at: expandedPath) else {
            return
        }
        try fileManager.removeItem(atPath: expandedPath)
    }

    func deduplicatedParentChildPaths(_ paths: [String]) -> [String] {
        let uniqueSortedPaths = Array(Set(paths.map(Self.normalizeSlashes))).sorted()

        var kept: [String] = []
        var keptPathSet: Set<String> = []
        for path in uniqueSortedPaths {
            if Self.hasKeptParent(for: path, in: keptPathSet) {
                continue
            }
            kept.append(path)
            keptPathSet.insert(path)
        }

        return kept
    }

    private func expandHome(in pattern: String) -> String {
        if pattern == "~" || pattern == "$HOME" || pattern == "${HOME}" {
            return homeDirectory
        }
        if pattern.hasPrefix("~/") {
            return homeDirectory + String(pattern.dropFirst())
        }
        if pattern.hasPrefix("$HOME/") {
            return homeDirectory + String(pattern.dropFirst("$HOME".count))
        }
        if pattern.hasPrefix("${HOME}/") {
            return homeDirectory + String(pattern.dropFirst("${HOME}".count))
        }
        return pattern
    }

    private func isSymlink(at path: String) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return false
        }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func containsGlob(_ pattern: String) -> Bool {
        pattern.contains { "*?[".contains($0) }
    }

    private static func globPaths(matching pattern: String) throws -> [String] {
        var globResult = glob_t()
        defer { globfree(&globResult) }

        let status = pattern.withCString { glob($0, 0, nil, &globResult) }
        if status == GLOB_NOMATCH {
            return []
        }
        guard status == 0 else {
            throw DiskCleanFileSystemError.globFailed(pattern: pattern, status: status)
        }
        guard let pathVector = globResult.gl_pathv else {
            return []
        }

        return (0..<Int(globResult.gl_pathc)).compactMap { index in
            guard let pathPointer = pathVector[index] else { return nil }
            return normalizeSlashes(String(cString: pathPointer))
        }
    }

    private static func hasKeptParent(for path: String, in keptPathSet: Set<String>) -> Bool {
        var currentPath = path
        while let slashIndex = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[..<slashIndex])
            if currentPath.isEmpty {
                currentPath = "/"
            }
            if keptPathSet.contains(currentPath) {
                return true
            }
            if currentPath == "/" {
                break
            }
        }
        return false
    }

    private enum DiskCleanFileSystemError: LocalizedError {
        case globFailed(pattern: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case let .globFailed(pattern, status):
                return "Failed to expand path pattern \(pattern) (glob status \(status))"
            }
        }
    }

    private static func normalizeSlashes(_ path: String) -> String {
        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        return normalized
    }
}

/// 物理路径规范化（设计 §13-6）。
///
/// 喂给 sizing 与执行的路径必须不含符号链接祖先，否则 `O_NOFOLLOW_ANY` 会直接 ELOOP
/// 拒绝（`/var`、`/tmp` 本身就是符号链接）。
///
/// **只解析父目录，末级组件原样保留**：末级本身可能就是候选 symlink，用 `realpath` 整条解析
/// 会把它换成指向的目标——那意味着去删别的东西。`URL.resolvingSymlinksInPath()` 也不行，
/// 它不展开 `/var`，语义正好相反。
enum DiskCleanPhysicalPath {
    static func resolve(_ path: String) -> String {
        guard let location = ParentAnchoredPath(path: path) else { return path }
        guard let physicalParent = realpath(of: location.parentPath) else { return path }
        return physicalParent == "/" ? "/" + location.name : physicalParent + "/" + location.name
    }

    static func realpath(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &buffer) != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// glob 的固定目录前缀：首个通配符之前的最后一个完整路径组件。
///
/// 所有权归属（设计 §5.3 第 1 条）用它的长度衡量"哪个 target 更特定"：
/// `~/Library/Caches/com.apple.akd` 比 `~/Library/Caches/*` 更特定，因此同一路径归前者。
enum DiskCleanGlobPrefix {
    static func fixedPrefix(of glob: String) -> String {
        guard let wildcardIndex = glob.firstIndex(where: { "*?[".contains($0) }) else {
            return glob
        }
        let head = glob[glob.startIndex..<wildcardIndex]
        guard let separatorIndex = head.lastIndex(of: "/") else { return "" }
        return String(head[head.startIndex..<separatorIndex])
    }
}
