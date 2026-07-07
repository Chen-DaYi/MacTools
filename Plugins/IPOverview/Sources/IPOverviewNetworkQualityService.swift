import Foundation
import MacToolsPluginKit

protocol IPOverviewNetworkQualityMeasuring: Sendable {
    func measure(
        onProgress: @escaping @Sendable (IPOverviewNetworkQualityProgressEvent) async -> Void
    ) async -> IPOverviewNetworkQualityMeasurementResult
}

enum IPOverviewNetworkQualityMeasurementResult: Equatable, Sendable {
    case success(IPOverviewNetworkQualityMeasurement)
    case failure(String)
}

enum IPOverviewNetworkQualityProgressEvent: Equatable, Sendable {
    case phase(IPOverviewNetworkQualityPhase)
    case download(Double)
    case upload(Double)
}

struct IPOverviewNetworkQualityService: IPOverviewNetworkQualityMeasuring {
    private let executableURL: URL
    private let pseudoTerminalExecutableURL: URL?
    private let maximumRuntimeSeconds: Int
    private let localization: PluginLocalization

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/networkQuality"),
        pseudoTerminalExecutableURL: URL? = URL(fileURLWithPath: "/usr/bin/script"),
        maximumRuntimeSeconds: Int = 12,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.executableURL = executableURL
        self.pseudoTerminalExecutableURL = pseudoTerminalExecutableURL
        self.maximumRuntimeSeconds = maximumRuntimeSeconds
        self.localization = localization
    }

    func measure(
        onProgress: @escaping @Sendable (IPOverviewNetworkQualityProgressEvent) async -> Void = { _ in }
    ) async -> IPOverviewNetworkQualityMeasurementResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .failure(localization.string(
                "speed.error.unavailable",
                defaultValue: "当前系统不可用 networkQuality"
            ))
        }

        do {
            let data = try await runNetworkQuality(onProgress: onProgress)
            guard let measurement = IPOverviewNetworkQualityParser.measurement(from: data) else {
                return .failure(localization.string(
                    "speed.error.invalidOutput",
                    defaultValue: "测速结果格式不可读"
                ))
            }

            return .success(measurement)
        } catch is CancellationError {
            return .failure(localization.string("speed.error.cancelled", defaultValue: "测速已取消"))
        } catch {
            return .failure(Self.userFacingMessage(for: error, localization: localization))
        }
    }

    private func runNetworkQuality(
        onProgress: @escaping @Sendable (IPOverviewNetworkQualityProgressEvent) async -> Void
    ) async throws -> Data {
        let processBox = IPOverviewNetworkQualityProcessBox()
        return try await withTaskCancellationHandler {
            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()
            let outputBuffer = IPOverviewNetworkQualityOutputBuffer()
            let launch = launchConfiguration()
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.standardOutput = pipe
            process.standardError = errorPipe
            processBox.process = process

            return try await withCheckedThrowingContinuation { continuation in
                let state = IPOverviewNetworkQualityResumeState()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        return
                    }

                    outputBuffer.append(data)
                    if let text = String(data: data, encoding: .utf8) {
                        let events = IPOverviewNetworkQualityParser.progressEvents(from: text)
                        for event in events {
                            Task {
                                await onProgress(event)
                            }
                        }
                    }
                }
                process.terminationHandler = { terminatedProcess in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let outputData = outputBuffer.data
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    processBox.process = nil
                    state.resume {
                        if terminatedProcess.terminationStatus == 0, !outputData.isEmpty {
                            continuation.resume(returning: outputData)
                        } else {
                            continuation.resume(throwing: IPOverviewNetworkQualityServiceError.failed(errorData))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    state.resume {
                        continuation.resume(throwing: error)
                    }
                }

                if Task.isCancelled {
                    process.terminate()
                    processBox.process = nil
                    state.resume {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            processBox.terminate()
        }
    }

    private func launchConfiguration() -> (executableURL: URL, arguments: [String]) {
        let arguments = ["-v", "-s", "-M", "\(maximumRuntimeSeconds)"]
        if let pseudoTerminalExecutableURL,
           FileManager.default.isExecutableFile(atPath: pseudoTerminalExecutableURL.path) {
            return (
                pseudoTerminalExecutableURL,
                ["-q", "/dev/null", executableURL.path] + arguments
            )
        }

        return (executableURL, arguments)
    }

    private static func userFacingMessage(
        for error: Error,
        localization: PluginLocalization
    ) -> String {
        if let serviceError = error as? IPOverviewNetworkQualityServiceError {
            return serviceError.localizedDescription(localization: localization)
        }

        return error.localizedDescription
    }
}

private final class IPOverviewNetworkQualityProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcess: Process?

    var process: Process? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProcess
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedProcess = newValue
        }
    }

    func terminate() {
        let process = process
        process?.terminate()
    }
}

private final class IPOverviewNetworkQualityResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else {
            return
        }

        didResume = true
        block()
    }
}

private final class IPOverviewNetworkQualityOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }
}

enum IPOverviewNetworkQualityServiceError: Error {
    case failed(Data)

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .failed(let data):
            if let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty {
                return message
            }

            return localization.string("speed.error.failed", defaultValue: "测速失败")
        }
    }
}

enum IPOverviewNetworkQualityParser {
    static func progressEvents(from text: String) -> [IPOverviewNetworkQualityProgressEvent] {
        let ttyEvents = ttyProgressEvents(from: text)
        if !ttyEvents.isEmpty {
            return ttyEvents
        }

        var events: [IPOverviewNetworkQualityProgressEvent] = []
        let lowercasedText = text.lowercased()
        if lowercasedText.contains("downlink capacity")
            || lowercasedText.contains("downlink: capacity")
            || lowercasedText.contains("downlink bytes") {
            events.append(.phase(.measuringDownload))
        }
        if lowercasedText.contains("uplink capacity")
            || lowercasedText.contains("uplink: capacity")
            || lowercasedText.contains("uplink bytes") {
            events.append(.phase(.measuringUpload))
        }
        if lowercasedText.contains("latency") || lowercasedText.contains("responsiveness") {
            events.append(.phase(.measuringLatency))
        }
        events.append(contentsOf: allDoubles(pattern: #"Downlink capacity:\s*([0-9.]+)\s*Mbps"#, in: text).map {
            .download($0)
        })
        events.append(contentsOf: allDoubles(pattern: #"Downlink:\s*capacity\s*([0-9.]+)\s*Mbps"#, in: text).map {
            .download($0)
        })
        events.append(contentsOf: allDoubles(pattern: #"Uplink capacity:\s*([0-9.]+)\s*Mbps"#, in: text).map {
            .upload($0)
        })
        events.append(contentsOf: allDoubles(pattern: #"Uplink:\s*capacity\s*([0-9.]+)\s*Mbps"#, in: text).map {
            .upload($0)
        })
        return events
    }

    private static func ttyProgressEvents(from text: String) -> [IPOverviewNetworkQualityProgressEvent] {
        let matches = allCapturePairs(
            pattern: #"Downlink:\s*capacity\s*([0-9.]+)\s*Mbps[\s\S]*?Uplink:\s*capacity\s*([0-9.]+)\s*Mbps"#,
            in: text
        )

        return matches.flatMap { downloadText, uploadText -> [IPOverviewNetworkQualityProgressEvent] in
            let download = Double(downloadText) ?? 0
            let upload = Double(uploadText) ?? 0
            if upload > 0 {
                return [.phase(.measuringUpload), .upload(upload)]
            }
            if download > 0 {
                return [.phase(.measuringDownload), .download(download)]
            }

            return [.phase(.initializing)]
        }
    }

    static func measurement(from data: Data) -> IPOverviewNetworkQualityMeasurement? {
        if let jsonMeasurement = jsonMeasurement(from: data) {
            return jsonMeasurement
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return verboseMeasurement(from: text)
    }

    private static func jsonMeasurement(from data: Data) -> IPOverviewNetworkQualityMeasurement? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return IPOverviewNetworkQualityMeasurement(
            baseRTTMilliseconds: doubleValue(for: "base_rtt", in: object),
            downloadThroughputBitsPerSecond: doubleValue(for: "dl_throughput", in: object),
            uploadThroughputBitsPerSecond: doubleValue(for: "ul_throughput", in: object),
            downloadResponsivenessRPM: doubleValue(for: "dl_responsiveness", in: object),
            uploadResponsivenessRPM: doubleValue(for: "ul_responsiveness", in: object),
            downloadPhaseDuration: doubleValue(for: "dl_phase_duration", in: object),
            uploadPhaseDuration: doubleValue(for: "ul_phase_duration", in: object),
            interfaceName: object["interface_name"] as? String,
            testEndpoint: object["test_endpoint"] as? String,
            startDate: object["start_date"] as? String,
            endDate: object["end_date"] as? String
        )
    }

    private static func verboseMeasurement(from text: String) -> IPOverviewNetworkQualityMeasurement? {
        let downloadMbps = firstDouble(pattern: #"Downlink capacity:\s*([0-9.]+)\s*Mbps"#, in: text)
        let uploadMbps = firstDouble(pattern: #"Uplink capacity:\s*([0-9.]+)\s*Mbps"#, in: text)
        let baseRTT = firstDouble(pattern: #"Idle Latency:\s*(?:[0-9.]+\s*RPM\s*\()?([0-9.]+)\s*milliseconds"#, in: text)
            ?? firstDouble(pattern: #"Idle Latency:\s*([0-9.]+)\s*milliseconds"#, in: text)
        let uploadResponsiveness = firstDouble(pattern: #"Uplink Responsiveness:[^\n]*\([0-9.]+\s*milliseconds\s*\|\s*([0-9.]+)\s*RPM\)"#, in: text)
            ?? firstDouble(pattern: #"Uplink Responsiveness:[\s\S]*?\n\s*([0-9.]+)\s*RPM"#, in: text)
        let downloadResponsiveness = firstDouble(pattern: #"Downlink Responsiveness:[^\n]*\([0-9.]+\s*milliseconds\s*\|\s*([0-9.]+)\s*RPM\)"#, in: text)
            ?? firstDouble(pattern: #"Downlink Responsiveness:[\s\S]*?\n\s*([0-9.]+)\s*RPM"#, in: text)

        guard downloadMbps != nil || uploadMbps != nil || baseRTT != nil else {
            return nil
        }

        return IPOverviewNetworkQualityMeasurement(
            baseRTTMilliseconds: baseRTT,
            downloadThroughputBitsPerSecond: downloadMbps.map { $0 * 1_000_000 },
            uploadThroughputBitsPerSecond: uploadMbps.map { $0 * 1_000_000 },
            downloadResponsivenessRPM: downloadResponsiveness,
            uploadResponsivenessRPM: uploadResponsiveness,
            downloadPhaseDuration: firstDouble(pattern: #"Downlink Phase Length:\s*([0-9.]+)s"#, in: text),
            uploadPhaseDuration: firstDouble(pattern: #"Uplink Phase Length:\s*([0-9.]+)s"#, in: text),
            interfaceName: firstCapture(pattern: #"Interface:\s*(\S+)"#, in: text),
            testEndpoint: firstCapture(pattern: #"Test Endpoint:\s*(\S+)"#, in: text),
            startDate: firstCapture(pattern: #"Start:\s*([^\n]+)"#, in: text),
            endDate: firstCapture(pattern: #"End:\s*([^\n]+)"#, in: text)
        )
    }

    private static func doubleValue(for key: String, in object: [String: Any]) -> Double? {
        switch object[key] {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    private static func firstDouble(pattern: String, in text: String) -> Double? {
        guard let value = firstCapture(pattern: pattern, in: text) else {
            return nil
        }

        return Double(value)
    }

    private static func allDoubles(pattern: String, in text: String) -> [Double] {
        allCaptures(pattern: pattern, in: text).compactMap(Double.init)
    }

    private static func allCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else {
                return nil
            }

            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private static func allCapturePairs(pattern: String, in text: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        return matches.compactMap { match -> (String, String)? in
            guard match.numberOfRanges > 2,
                  let firstRange = Range(match.range(at: 1), in: text),
                  let secondRange = Range(match.range(at: 2), in: text)
            else {
                return nil
            }

            return (
                String(text[firstRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(text[secondRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
