import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

private enum RecorderError: LocalizedError {
    case invalidArguments
    case invalidRectangle(String)
    case rectangleSpansDisplays
    case missingApplication(String)
    case startTimedOut
    case cannotAddWriterInput
    case writerDidNotStart
    case noVideoFrames
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "usage: MacToolsE2ERecorder.swift <output.mov> <seconds> <x,y,width,height> <ready-file> <start-file> <stop-file> <allowed-bundle-id>..."
        case let .invalidRectangle(value):
            return "invalid capture rectangle: \(value)"
        case .rectangleSpansDisplays:
            return "the private capture rectangle must be fully contained by one display"
        case let .missingApplication(bundleIdentifier):
            return "allowed capture application is not running: \(bundleIdentifier)"
        case .startTimedOut:
            return "the story did not start within 60 seconds of recorder readiness"
        case .cannotAddWriterInput:
            return "the video writer rejected its input configuration"
        case .writerDidNotStart:
            return "the video writer could not start"
        case .noVideoFrames:
            return "the filtered capture produced no video frames"
        case let .writerFailed(detail):
            return "the video writer failed: \(detail)"
        }
    }
}

private struct CaptureRequest {
    let outputURL: URL
    let duration: TimeInterval
    let rectangle: CGRect
    let readyURL: URL
    let startURL: URL
    let stopURL: URL
    let allowedBundleIdentifiers: Set<String>

    init(arguments: [String]) throws {
        guard arguments.count >= 9,
              let duration = TimeInterval(arguments[2]),
              duration >= 1,
              duration <= 600 else {
            throw RecorderError.invalidArguments
        }

        let components = arguments[3].split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard components.count == 4,
              components[0].isFinite,
              components[1].isFinite,
              components[2].isFinite,
              components[3].isFinite,
              components[2] >= 320,
              components[3] >= 240 else {
            throw RecorderError.invalidRectangle(arguments[3])
        }

        let identifiers = Set(arguments.dropFirst(7).filter { !$0.isEmpty })
        guard !identifiers.isEmpty else {
            throw RecorderError.invalidArguments
        }

        outputURL = URL(fileURLWithPath: arguments[1])
        self.duration = duration
        rectangle = CGRect(
            x: components[0],
            y: components[1],
            width: components[2],
            height: components[3]
        )
        readyURL = URL(fileURLWithPath: arguments[4])
        startURL = URL(fileURLWithPath: arguments[5])
        stopURL = URL(fileURLWithPath: arguments[6])
        allowedBundleIdentifiers = identifiers
    }
}

private final class VideoWriterOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue: DispatchQueue
    private var didStartWriting = false
    private var frameCount = 0
    private var appendFailure: String?
    private var firstPresentationTime: CMTime?
    private var isCaptureEnabled = false

    init(outputURL: URL, width: Int, height: Int, queue: DispatchQueue) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(4_000_000, width * height * 5),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        self.queue = queue
        super.init()

        guard writer.canAdd(input) else {
            throw RecorderError.cannotAddWriterInput
        }
        writer.add(input)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              isCaptureEnabled,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !didStartWriting {
            guard writer.startWriting() else {
                appendFailure = Self.errorDetail(writer.error)
                return
            }
            writer.startSession(atSourceTime: .zero)
            firstPresentationTime = sourceTime
            didStartWriting = true
        }

        guard input.isReadyForMoreMediaData,
              let firstPresentationTime else {
            return
        }
        let presentationTime = CMTimeSubtract(sourceTime, firstPresentationTime)
        guard let ownedPixelBuffer = copyPixelBuffer(pixelBuffer) else {
            appendFailure = "could not copy a ScreenCaptureKit frame into the private writer pool"
            return
        }
        if adaptor.append(ownedPixelBuffer, withPresentationTime: presentationTime) {
            frameCount += 1
        } else {
            appendFailure = Self.errorDetail(writer.error)
        }
    }

    func enableCapture() {
        queue.sync {
            isCaptureEnabled = true
        }
    }

    func finish() async throws -> Int {
        let started = queue.sync {
            guard didStartWriting else {
                return false
            }
            input.markAsFinished()
            return true
        }

        guard started else {
            throw RecorderError.writerDidNotStart
        }
        if let appendFailure {
            writer.cancelWriting()
            throw RecorderError.writerFailed(appendFailure)
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw RecorderError.writerFailed(
                Self.errorDetail(writer.error, fallback: "status \(writer.status.rawValue)")
            )
        }
        guard frameCount > 0 else {
            throw RecorderError.noVideoFrames
        }
        return frameCount
    }

    private static func errorDetail(_ error: Error?, fallback: String = "unknown failure") -> String {
        guard let error else { return fallback }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination,
              !CVPixelBufferIsPlanar(source),
              !CVPixelBufferIsPlanar(destination),
              CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            return nil
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let byteCount = min(sourceBytesPerRow, destinationBytesPerRow)
        for row in 0..<CVPixelBufferGetHeight(source) {
            memcpy(
                destinationBase.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * sourceBytesPerRow),
                byteCount
            )
        }
        return destination
    }
}

private func evenPixelCount(_ value: CGFloat) -> Int {
    let rounded = max(2, Int(value.rounded()))
    return rounded.isMultiple(of: 2) ? rounded : rounded - 1
}

private func record(_ request: CaptureRequest) async throws -> Int {
    let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
    )

    guard let display = content.displays.first(where: {
        $0.frame.contains(request.rectangle)
    }) else {
        throw RecorderError.rectangleSpansDisplays
    }

    let applicationsByIdentifier = Dictionary(
        grouping: content.applications.map { application in
            (application.bundleIdentifier, application)
        },
        by: { $0.0 }
    )
    var allowedApplications: [SCRunningApplication] = []
    for identifier in request.allowedBundleIdentifiers.sorted() {
        guard let applications = applicationsByIdentifier[identifier]?.map(\.1),
              !applications.isEmpty else {
            throw RecorderError.missingApplication(identifier)
        }
        allowedApplications.append(contentsOf: applications)
    }

    let scale = CGFloat(display.width) / display.frame.width
    let relativeRectangle = CGRect(
        x: request.rectangle.minX - display.frame.minX,
        y: request.rectangle.minY - display.frame.minY,
        width: request.rectangle.width,
        height: request.rectangle.height
    )
    let pixelWidth = evenPixelCount(relativeRectangle.width * scale)
    let pixelHeight = evenPixelCount(relativeRectangle.height * scale)

    let filter = SCContentFilter(
        display: display,
        including: allowedApplications,
        exceptingWindows: []
    )
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = relativeRectangle
    configuration.width = pixelWidth
    configuration.height = pixelHeight
    configuration.scalesToFit = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.queueDepth = 6
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = true
    configuration.capturesAudio = false
    if #available(macOS 15.0, *) {
        configuration.showMouseClicks = true
    }

    try? FileManager.default.removeItem(at: request.outputURL)
    try? FileManager.default.removeItem(at: request.readyURL)
    try? FileManager.default.removeItem(at: request.startURL)
    try? FileManager.default.removeItem(at: request.stopURL)
    let outputQueue = DispatchQueue(label: "com.jennymedia.mactools.e2e-recorder.frames")
    let output = try VideoWriterOutput(
        outputURL: request.outputURL,
        width: pixelWidth,
        height: pixelHeight,
        queue: outputQueue
    )
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)

    try await stream.startCapture()
    try Data().write(to: request.readyURL, options: .atomic)
    let clock = ContinuousClock()
    let startDeadline = clock.now.advanced(by: .seconds(60))
    while clock.now < startDeadline,
          !FileManager.default.fileExists(atPath: request.startURL.path) {
        try await Task.sleep(for: .milliseconds(50))
    }
    guard FileManager.default.fileExists(atPath: request.startURL.path) else {
        try? await stream.stopCapture()
        throw RecorderError.startTimedOut
    }
    output.enableCapture()
    let deadline = clock.now.advanced(by: .seconds(request.duration))
    while clock.now < deadline,
          !FileManager.default.fileExists(atPath: request.stopURL.path) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try await stream.stopCapture()
    return try await output.finish()
}

@main
private struct MacToolsE2ERecorder {
    static func main() async {
        do {
            let request = try CaptureRequest(arguments: CommandLine.arguments)
            let frameCount = try await record(request)
            print("frames=\(frameCount)")
            print("privacyFilter=application-allowlist")
            print("mouseClickIndicators=enabled")
            print("allowedBundleIdentifiers=\(request.allowedBundleIdentifiers.sorted().joined(separator: ","))")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
