import Foundation

public enum HomebrewExecutableValidator {
    public static let standardPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/opt/workbrew/bin/brew"
    ]

    public static func validatedPath(
        for rawPath: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = (trimmed as NSString).expandingTildeInPath
        if (candidate as NSString).lastPathComponent != "brew" {
            candidate = (candidate as NSString).appendingPathComponent("brew")
        }

        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL
        guard isValidBrewExecutable(at: standardized.path, fileManager: fileManager) else {
            return nil
        }
        return standardized.path
    }

    public static func isValidBrewExecutable(
        at path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "brew",
              url.deletingLastPathComponent().lastPathComponent == "bin" else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: url.path) else {
            return false
        }

        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        var resolvedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &resolvedIsDirectory),
              !resolvedIsDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolvedURL.path) else {
            return false
        }

        return looksLikeHomebrewExecutable(at: resolvedURL)
            || looksLikeHomebrewExecutable(at: url)
    }

    private static func looksLikeHomebrewExecutable(at url: URL) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.read(upToCount: 16_384),
              let sample = String(data: data, encoding: .utf8) else {
            return false
        }

        return sample.contains("HOMEBREW")
            || sample.contains("Homebrew")
            || sample.contains("brew.rb")
    }
}

public protocol HomebrewCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        onOutput: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws -> Int32
    
    func cancel() async
}

public actor HomebrewCommandRunner: HomebrewCommandRunning {
    private var activeProcess: Process?

    public init() {}

    /// Runs a command asynchronously, streaming output and error chunks to the provided handlers.
    /// Returns the termination status (exit code).
    public func run(
        executable: String,
        arguments: [String],
        onOutput: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws -> Int32 {
        if activeProcess != nil {
            throw NSError(
                domain: "HomebrewCommandRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A process is already running."]
            )
        }

        let process = Process()
        guard let validatedExecutable = HomebrewExecutableValidator.validatedPath(for: executable) else {
            throw NSError(
                domain: "HomebrewCommandRunner",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The configured Homebrew executable is invalid."]
            )
        }

        process.executableURL = URL(fileURLWithPath: validatedExecutable)
        
        // Setup environment path, ensuring homebrew binaries are visible
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        let brewPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        var pathComponents = path.components(separatedBy: ":")
        for p in brewPaths {
            if !pathComponents.contains(p) {
                pathComponents.insert(p, at: 0)
            }
        }
        env["PATH"] = pathComponents.joined(separator: ":")
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.activeProcess = process

        let group = DispatchGroup()

        // Attach readability handlers to stream output in real-time
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let string = String(data: data, encoding: .utf8) {
                group.enter()
                Task { @MainActor in
                    onOutput(string)
                    group.leave()
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let string = String(data: data, encoding: .utf8) {
                group.enter()
                Task { @MainActor in
                    onError(string)
                    group.leave()
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                // Clear readability handlers to prevent resource leaks
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                Task { [weak self] in
                    guard let self = self else { return }
                    
                    // Wait for all pending UI output tasks to complete
                    await withCheckedContinuation { (waitContinuation: CheckedContinuation<Void, Never>) in
                        group.notify(queue: .global()) {
                            waitContinuation.resume()
                        }
                    }
                    
                    await self.clearProcess(for: proc)
                    continuation.resume(returning: proc.terminationStatus)
                }
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                Task { [weak self] in
                    guard let self = self else { return }
                    await self.clearProcess(for: process)
                }
                continuation.resume(throwing: error)
            }
        }
    }

    public func cancel() {
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
    }

    private func clearProcess(for process: Process) {
        if self.activeProcess === process {
            self.activeProcess = nil
        }
    }
}
