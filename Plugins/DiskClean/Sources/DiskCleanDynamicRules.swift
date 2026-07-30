import Darwin
import Foundation
import os

// MARK: - 协议

/// 动态规则展开（设计 §5.5）。
///
/// 语义约定：
/// - **"目标不存在"返回空数组**（未装 Xcode、版本目录不存在），不算失败。
/// - **真正的失败 `throw`**：子进程超时、输出畸形。调用方（ScanEngine）负责把 throw 转成
///   `dynamicRuleFailed` limitation + 保留前缀后继续扫描，绝不让动态规则阻塞整次扫描。
/// - 失败时**不返回部分结果**：宁可整块跳过（配合 target 的 `reservedRootPaths` 做祖先保护），
///   也不把"只展开了一半"的候选当完整结果交出去。
protocol DiskCleanDynamicRuleProviding: Sendable {
    func expand() async throws -> [DiskCleanFileItem]
}

enum DiskCleanDynamicRuleError: Error, Equatable {
    /// 子进程输出不是预期结构（JSON 畸形、缺关键字段、被截断）。
    case malformedOutput(command: String)
    /// 目录可见但无法列出（权限等）。
    case directoryUnreadable(path: String)
}

// MARK: - 子进程执行 seam

struct DiskCleanSubprocessResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data
}

enum DiskCleanSubprocessError: Error, Equatable {
    /// 可执行文件不存在或不可执行（例如未安装命令行工具）。
    case executableUnavailable(path: String)
    case launchFailed(path: String, message: String)
    case timedOut(path: String)
}

/// 子进程执行 seam。测试注入 fake 以覆盖正常/畸形/超时/命令缺失矩阵。
protocol DiskCleanSubprocessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult
}

/// 真实实现：管道读取与超时竞争——超时分支终止子进程，子进程退出即 EOF，读取分支随之返回。
struct LocalDiskCleanSubprocessRunner: DiskCleanSubprocessRunning {
    /// 输出上限。超出即停止读取，JSON 解析随后失败为 `malformedOutput`，不无界占用内存。
    static let maximumOutputBytes = 8 * 1024 * 1024

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw DiskCleanSubprocessError.executableUnavailable(path: executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process: process)
        do {
            try process.run()
        } catch {
            throw DiskCleanSubprocessError.launchFailed(
                path: executablePath,
                message: error.localizedDescription
            )
        }

        let readDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            box.terminate(markingTimeout: true)
        }

        // 调用方取消时同样终止子进程：阻塞的 read(2) 不响应 task 取消，只能靠子进程退出关闭管道。
        let output = await withTaskCancellationHandler {
            await Self.drain(fileDescriptor: readDescriptor)
        } onCancel: {
            box.terminate(markingTimeout: false)
        }

        box.waitUntilExit()
        timeoutTask.cancel()
        try? outputPipe.fileHandleForReading.close()

        if box.didTimeOut {
            throw DiskCleanSubprocessError.timedOut(path: executablePath)
        }
        return DiskCleanSubprocessResult(exitCode: box.terminationStatus, standardOutput: output)
    }

    private static func drain(fileDescriptor: Int32) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var output = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while output.count < maximumOutputBytes {
                    let count = buffer.withUnsafeMutableBytes {
                        read(fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        output.append(contentsOf: buffer[0..<count])
                        continue
                    }
                    if count < 0 && errno == EINTR {
                        continue
                    }
                    break
                }
                continuation.resume(returning: output)
            }
        }
    }

    /// `Process` 不是 `Sendable`，但 `terminate()`/`isRunning` 可跨线程调用。
    /// 用一把锁串行化"终止 + 标记超时"，并保证进程已退出时不再误判为超时。
    private final class ProcessBox: @unchecked Sendable {
        private struct Flags: Sendable {
            var timedOut = false
        }

        private let process: Process
        private let flags = OSAllocatedUnfairLock(initialState: Flags())

        init(process: Process) {
            self.process = process
        }

        func terminate(markingTimeout: Bool) {
            flags.withLock { flags in
                guard process.isRunning else { return }
                if markingTimeout {
                    flags.timedOut = true
                }
                process.terminate()
            }
        }

        func waitUntilExit() {
            process.waitUntilExit()
        }

        var terminationStatus: Int32 {
            process.terminationStatus
        }

        var didTimeOut: Bool {
            flags.withLock { $0.timedOut }
        }
    }
}

// MARK: - 版本号

/// 版本目录名。仅接受以数字开头、以 `.` 分段且每段以数字开头的名称，
/// 因此 `Current`、`ch-0`、`crx_cache`、`prefs.json` 一律不会被当成版本。
struct DiskCleanVersionNumber: Comparable, Equatable, Sendable {
    let components: [Int]
    let rawName: String

    init?(_ rawName: String) {
        guard let first = rawName.first, first.isNumber else { return nil }
        var components: [Int] = []
        for segment in rawName.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = segment.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
        self.rawName = rawName
    }

    static func < (lhs: DiskCleanVersionNumber, rhs: DiskCleanVersionNumber) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        // 数值完全相同时按名称排序，保证顺序稳定可测。
        return lhs.rawName < rhs.rawName
    }
}

// MARK: - 版本目录 provider

/// 版本目录比较：容器目录下的版本子目录保留最新若干个，其余作为候选（设计 §5.5）。
///
/// 三条安全约束：
/// 1. 只收**真实目录**，符号链接与普通文件一律不收。
/// 2. 被同级符号链接（`Current`、`latest` 之类）指向的版本视为在用，永不作为候选。
/// 3. 版本数量不足 `keepNewestCount + 1` 时返回空——绝不清空一个只有一两个版本的目录。
struct DiskCleanVersionDirectoryRuleProvider: DiskCleanDynamicRuleProviding {
    /// 容器目录 glob。展开结果的**直接子项**参与版本比较（容器自身永不作为候选）。
    let containerGlobs: [String]
    let keepNewestCount: Int
    let fileSystem: DiskCleanFileSystemProviding

    init(
        containerGlobs: [String],
        keepNewestCount: Int = 1,
        fileSystem: DiskCleanFileSystemProviding = LocalDiskCleanFileSystem()
    ) {
        self.containerGlobs = containerGlobs
        self.keepNewestCount = max(keepNewestCount, 1)
        self.fileSystem = fileSystem
    }

    func expand() async throws -> [DiskCleanFileItem] {
        var items: [DiskCleanFileItem] = []
        for containerGlob in containerGlobs {
            let containers: [DiskCleanFileItem]
            do {
                containers = try fileSystem.expandPathPattern(containerGlob)
            } catch {
                throw DiskCleanDynamicRuleError.directoryUnreadable(path: containerGlob)
            }
            for container in containers where container.isDirectory && !container.isSymlink {
                items += try obsoleteVersions(in: container.path)
            }
        }
        return items
    }

    private func obsoleteVersions(in containerPath: String) throws -> [DiskCleanFileItem] {
        let children: [DiskCleanFileItem]
        do {
            children = try fileSystem.expandPathPattern(containerPath + "/*")
        } catch {
            throw DiskCleanDynamicRuleError.directoryUnreadable(path: containerPath)
        }

        let pinnedNames = Set(children.compactMap(Self.pinnedVersionName))
        var versions: [(version: DiskCleanVersionNumber, item: DiskCleanFileItem)] = []
        for child in children where child.isDirectory && !child.isSymlink {
            let name = (child.path as NSString).lastPathComponent
            guard !pinnedNames.contains(name), let version = DiskCleanVersionNumber(name) else { continue }
            versions.append((version, child))
        }

        guard versions.count > keepNewestCount else { return [] }
        return versions
            .sorted { $0.version > $1.version }
            .dropFirst(keepNewestCount)
            .map(\.item)
    }

    /// 同级符号链接指向的版本名（`Current -> 152.0.7933.0`）。相对与绝对目标都只取末级组件。
    private static func pinnedVersionName(for item: DiskCleanFileItem) -> String? {
        guard item.isSymlink, let target = item.resolvedSymlinkTarget else { return nil }
        let name = (target as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

// MARK: - 不可用模拟器 provider

/// `xcrun simctl list devices -j` 中 `isAvailable == false` 的设备目录（设计 §5.5）。
///
/// 设备目录一律由 `devicesRootPath + udid` 拼装，不采信 JSON 里的 `dataPath`/`logPath`——
/// 候选路径必须落在本 target 声明的保留根内，而不是由外部命令输出决定删哪里。
struct DiskCleanUnavailableSimulatorRuleProvider: DiskCleanDynamicRuleProviding {
    let devicesRootPath: String
    let executablePath: String
    let timeout: Duration
    let subprocessRunner: any DiskCleanSubprocessRunning
    let fileSystem: DiskCleanFileSystemProviding

    init(
        devicesRootPath: String = "~/Library/Developer/CoreSimulator/Devices",
        executablePath: String = "/usr/bin/xcrun",
        timeout: Duration = DiskCleanDynamicRuleProviders.subprocessTimeout,
        subprocessRunner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner(),
        fileSystem: DiskCleanFileSystemProviding = LocalDiskCleanFileSystem()
    ) {
        self.devicesRootPath = devicesRootPath
        self.executablePath = executablePath
        self.timeout = timeout
        self.subprocessRunner = subprocessRunner
        self.fileSystem = fileSystem
    }

    func expand() async throws -> [DiskCleanFileItem] {
        let result: DiskCleanSubprocessResult
        do {
            result = try await subprocessRunner.run(
                executablePath: executablePath,
                arguments: ["simctl", "list", "devices", "-j"],
                timeout: timeout
            )
        } catch DiskCleanSubprocessError.executableUnavailable {
            return []
        }

        // 非零退出的现实含义是 simctl 不可用（未装 Xcode 时 xcrun 报 "unable to find utility"），
        // 按设计视作"没有模拟器"返回空，而不是失败。
        guard result.exitCode == 0 else { return [] }

        var items: [DiskCleanFileItem] = []
        for udid in try Self.unavailableDeviceUDIDs(from: result.standardOutput) {
            guard let item = try? fileSystem.itemInfo(at: devicesRootPath + "/" + udid) else {
                continue
            }
            items.append(item)
        }
        return items
    }

    /// 解析 `isAvailable == false` 的设备 UDID。UDID 必须是合法 UUID，杜绝 `../` 之类路径注入。
    static func unavailableDeviceUDIDs(from output: Data) throws -> [String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
            let devicesByRuntime = root["devices"] as? [String: Any]
        else {
            throw DiskCleanDynamicRuleError.malformedOutput(command: "simctl list devices -j")
        }

        var udids: [String] = []
        for runtime in devicesByRuntime.keys.sorted() {
            guard let devices = devicesByRuntime[runtime] as? [[String: Any]] else { continue }
            for device in devices {
                guard device["isAvailable"] as? Bool == false else { continue }
                guard let udid = device["udid"] as? String, UUID(uuidString: udid) != nil else { continue }
                udids.append(udid)
            }
        }
        return udids
    }
}

// MARK: - 默认 provider 实例

/// 规则目录引用的默认 provider 实例。容器路径与各 target 的 `reservedRootPaths` 必须一致。
enum DiskCleanDynamicRuleProviders {
    /// 子进程统一超时（设计 §5.5）。
    static let subprocessTimeout: Duration = .seconds(2)

    static let unavailableSimulators: any DiskCleanDynamicRuleProviding =
        DiskCleanUnavailableSimulatorRuleProvider()

    /// JetBrains Toolbox：`apps/<IDE>/ch-<n>/<build>`（Toolbox 1.x）与 `apps/<IDE>/<build>`（较新布局）。
    /// 两层都扫，非版本名的中间目录（`ch-0`）自然被版本解析拒绝。
    static let jetbrainsToolboxOldVersions: any DiskCleanDynamicRuleProviding =
        DiskCleanVersionDirectoryRuleProvider(containerGlobs: [
            "~/Library/Application Support/JetBrains/Toolbox/apps/*/ch-*",
            "~/Library/Application Support/JetBrains/Toolbox/apps/*"
        ])

    /// AI 编码工具的多版本安装目录。目录不存在即静默跳过。
    static let aiAgentOldVersions: any DiskCleanDynamicRuleProviding =
        DiskCleanVersionDirectoryRuleProvider(containerGlobs: [
            "~/.local/share/claude/versions",
            "~/.claude/versions",
            "~/.codex/versions",
            "~/.local/share/opencode/versions"
        ])

    /// Chromium 系更新器保留的历史版本目录（`GoogleUpdater/<version>` + `Current` 符号链接）。
    static let oldBrowserVersions: any DiskCleanDynamicRuleProviding =
        DiskCleanVersionDirectoryRuleProvider(containerGlobs: [
            "~/Library/Application Support/Google/GoogleUpdater",
            "~/Library/Application Support/Microsoft/EdgeUpdater",
            "~/Library/Application Support/BraveSoftware/BraveUpdater"
        ])
}
