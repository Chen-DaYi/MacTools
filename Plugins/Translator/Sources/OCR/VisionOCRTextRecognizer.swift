import AppKit
import Foundation
import MacToolsPluginKit
import Vision

private final class TranslatorOCRBundleToken {}

@MainActor
protocol OCRTextRecognizing {
    func recognizeText(in image: NSImage) async throws -> OCRTextRecognitionResult
}

enum OCRTextRecognitionError: Error, Equatable, LocalizedError, Sendable {
    case invalidImage
    case emptyResult
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return PluginLocalization(bundle: Bundle(for: TranslatorOCRBundleToken.self)).string(
                "ocr.error.invalidImage",
                defaultValue: "无法读取截图。"
            )
        case .emptyResult:
            return PluginLocalization(bundle: Bundle(for: TranslatorOCRBundleToken.self)).string(
                "ocr.error.emptyResult",
                defaultValue: "截图中没有识别到文字。"
            )
        case let .requestFailed(message):
            return message
        }
    }
}

struct VisionOCRTextRecognizer: OCRTextRecognizing {
    func recognizeText(in image: NSImage) async throws -> OCRTextRecognitionResult {
        guard let cgImage = image.cgImageForOCR else {
            throw OCRTextRecognitionError.invalidImage
        }

        let lines = try await recognizeLines(
            in: cgImage,
            recognitionLanguages: nil,
            automaticallyDetectsLanguage: true
        )

        let fallbackLines: [OCRRecognizedLine]
        if lines.isEmpty {
            fallbackLines = try await recognizeLines(
                in: cgImage,
                recognitionLanguages: ["ja-JP"],
                automaticallyDetectsLanguage: false
            )
        } else {
            fallbackLines = lines
        }

        let text = OCRTextMerge.merge(fallbackLines)
        guard !text.isEmpty else {
            throw OCRTextRecognitionError.emptyResult
        }

        return OCRTextRecognitionResult(text: text, lines: fallbackLines)
    }

    private func recognizeLines(
        in cgImage: CGImage,
        recognitionLanguages: [String]?,
        automaticallyDetectsLanguage: Bool
    ) async throws -> [OCRRecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                if #available(macOS 13.0, *) {
                    request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
                }

                if let recognitionLanguages {
                    request.recognitionLanguages = recognitionLanguages
                }

                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    let recognizedLines = (request.results ?? []).compactMap { observation -> OCRRecognizedLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }
                        return OCRRecognizedLine(
                            text: candidate.string,
                            boundingBox: observation.boundingBox,
                            confidence: candidate.confidence
                        )
                    }
                    continuation.resume(returning: recognizedLines)
                } catch {
                    continuation.resume(throwing: OCRTextRecognitionError.requestFailed(error.localizedDescription))
                }
            }
        }
    }
}

private extension NSImage {
    var cgImageForOCR: CGImage? {
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
