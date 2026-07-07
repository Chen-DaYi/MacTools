import AppKit
import AVFoundation
import Foundation
import MacToolsPluginKit

@MainActor
protocol TranslatorPanelControlling: AnyObject {
    var onAction: ((TranslatorPanelAction) -> Void)? { get set }

    func show(snapshot: TranslatorPanelSnapshot)
    func update(snapshot: TranslatorPanelSnapshot)
    func close()
}

protocol TranslationProviding: Sendable {
    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection
    ) async throws -> TranslationResult
}

typealias TranslatorProviderFactory = @MainActor () -> TranslatorProviderBuildResult

struct OpenAITranslationProviderAdapter: TranslationProviding {
    let client: OpenAICompatibleClient
    let configuration: OpenAICompatibleConfiguration
    let apiKey: String
    let providerTitle: String

    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection
    ) async throws -> TranslationResult {
        var result = try await client.translate(
            text: text,
            languageSelection: languageSelection,
            configuration: configuration,
            apiKey: apiKey
        )
        result.providerTitle = providerTitle
        return result
    }
}

private struct ProviderTranslationOutcome: Sendable {
    var providerID: String
    var translation: TranslationResult?
    var errorMessage: String?
}

@MainActor
final class TranslatorCoordinator {
    private let selectedTextCapturePipeline: SelectedTextCapturePipeline
    private let screenshotRegionCapturer: (any ScreenshotRegionCapturing)?
    private let ocrTextRecognizer: (any OCRTextRecognizing)?
    private let languagePreferenceStore: LanguagePreferenceStore
    private let providerFactory: TranslatorProviderFactory
    private weak var panelController: TranslatorPanelControlling?
    private let localization: PluginLocalization
    private let speechSynthesizer = AVSpeechSynthesizer()

    private var sessionID = UUID()
    private var activeTask: Task<Void, Never>?
    private var lastSourceText: String?
    private var lastQuerySource: TranslatorQuerySource?

    private(set) var snapshot: TranslatorPanelSnapshot = .idle {
        didSet {
            panelController?.update(snapshot: snapshot)
        }
    }

    init(
        selectedTextCapturePipeline: SelectedTextCapturePipeline,
        screenshotRegionCapturer: (any ScreenshotRegionCapturing)? = nil,
        ocrTextRecognizer: (any OCRTextRecognizing)? = nil,
        languagePreferenceStore: LanguagePreferenceStore,
        providerFactory: @escaping TranslatorProviderFactory,
        panelController: TranslatorPanelControlling?,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.selectedTextCapturePipeline = selectedTextCapturePipeline
        self.screenshotRegionCapturer = screenshotRegionCapturer
        self.ocrTextRecognizer = ocrTextRecognizer
        self.languagePreferenceStore = languagePreferenceStore
        self.providerFactory = providerFactory
        self.panelController = panelController
        self.localization = localization
    }

    func startSelectTranslation() {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runSelectTranslation()
        }
    }

    func startScreenshotTranslation() {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runScreenshotTranslation()
        }
    }

    private func runSelectTranslation() async {
        let currentSessionID = UUID()
        sessionID = currentSessionID
        lastSourceText = nil
        lastQuerySource = .selectedText
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        panelController?.close()
        let providerBuildResult = providerFactory()
        let initialProviderResults = providerBuildResult.waitingProviderResults(localization: localization)
        snapshot = TranslatorPanelSnapshot(
            phase: .capturing,
            sourceText: nil,
            languageSelection: nil,
            translation: nil,
            providerResults: initialProviderResults,
            errorMessage: nil,
            querySource: .selectedText,
            captureStage: .selectedText
        )

        let result = await selectedTextCapturePipeline.capture(
            context: SelectedTextCaptureContext(
                frontmostApplication: frontmostApplication
            )
        )

        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        guard let sourceText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceText.isEmpty
        else {
            if result.failureReason == TranslatorPanelError.permissionRequired.message(localization: localization) {
                setError(
                    .permissionRequired,
                    sourceText: nil,
                    languageSelection: nil,
                    providerResults: initialProviderResults
                )
                panelController?.show(snapshot: snapshot)
                return
            }

            setError(
                .missingSelection,
                sourceText: nil,
                languageSelection: nil,
                providerResults: initialProviderResults
            )
            panelController?.show(snapshot: snapshot)
            return
        }

        lastSourceText = sourceText
        lastQuerySource = .selectedText

        await translateOrShowConfigurationError(
            sourceText: sourceText,
            querySource: .selectedText,
            providerBuildResult: providerBuildResult,
            providerResults: initialProviderResults,
            sessionID: currentSessionID
        )
    }

    private func runScreenshotTranslation() async {
        let currentSessionID = UUID()
        sessionID = currentSessionID
        lastSourceText = nil
        lastQuerySource = .screenshot
        panelController?.close()
        snapshot = TranslatorPanelSnapshot(
            phase: .capturing,
            sourceText: nil,
            languageSelection: nil,
            translation: nil,
            providerResults: [],
            errorMessage: nil,
            querySource: .screenshot,
            captureStage: .screenshotRegion
        )

        guard let screenshotRegionCapturer, let ocrTextRecognizer else {
            setError(
                .screenshotFailed,
                sourceText: nil,
                languageSelection: nil,
                providerResults: [],
                querySource: .screenshot
            )
            panelController?.show(snapshot: snapshot)
            return
        }

        let captureResult = await screenshotRegionCapturer.captureRegion()
        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        guard let screenshot = captureResult.image else {
            let panelError = Self.panelError(for: captureResult.error ?? .screenshotFailed)
            setError(
                panelError,
                sourceText: nil,
                languageSelection: nil,
                providerResults: [],
                querySource: .screenshot
            )
            panelController?.show(snapshot: snapshot)
            return
        }

        snapshot = TranslatorPanelSnapshot(
            phase: .capturing,
            sourceText: nil,
            languageSelection: nil,
            translation: nil,
            providerResults: [],
            errorMessage: nil,
            querySource: .screenshot,
            captureStage: .ocr
        )
        panelController?.show(snapshot: snapshot)

        do {
            let recognitionResult = try await ocrTextRecognizer.recognizeText(in: screenshot)
            guard !Task.isCancelled, sessionID == currentSessionID else { return }
            let sourceText = recognitionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceText.isEmpty else {
                setError(
                    .missingOCRText,
                    sourceText: nil,
                    languageSelection: nil,
                    providerResults: [],
                    querySource: .screenshot
                )
                panelController?.show(snapshot: snapshot)
                return
            }

            lastSourceText = sourceText
            lastQuerySource = .screenshot
            let providerBuildResult = providerFactory()
            let initialProviderResults = providerBuildResult.waitingProviderResults(localization: localization)
            await translateOrShowConfigurationError(
                sourceText: sourceText,
                querySource: .screenshot,
                providerBuildResult: providerBuildResult,
                providerResults: initialProviderResults,
                sessionID: currentSessionID
            )
        } catch {
            guard !Task.isCancelled, sessionID == currentSessionID else { return }
            let panelError = Self.panelError(forOCR: error, localization: localization)
            setError(
                panelError,
                sourceText: nil,
                languageSelection: nil,
                providerResults: [],
                querySource: .screenshot
            )
            panelController?.show(snapshot: snapshot)
        }
    }

    func handle(_ action: TranslatorPanelAction) async {
        switch action {
        case .retry:
            retry()
        case .close:
            close()
        case .copySource:
            copy(snapshot.sourceText)
        case .copyTranslation:
            copy(snapshot.translation?.text)
        case let .copyProviderTranslation(providerID):
            copy(snapshot.providerResults.first { $0.id == providerID }?.translation?.text)
        case .speakSource:
            speak(snapshot.sourceText, language: snapshot.languageSelection?.source)
        case .speakTranslation:
            speak(snapshot.translation?.text, language: snapshot.languageSelection?.target)
        case .openSettings:
            break
        }
    }

    func close() {
        sessionID = UUID()
        activeTask?.cancel()
        activeTask = nil
        panelController?.close()
    }

    private func retry() {
        guard let sourceText = lastSourceText else {
            if lastQuerySource == .screenshot {
                startScreenshotTranslation()
            } else {
                startSelectTranslation()
            }
            return
        }

        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runRetry(sourceText: sourceText)
        }
    }

    private func runRetry(sourceText: String) async {
        let currentSessionID = UUID()
        sessionID = currentSessionID
        let querySource = lastQuerySource
        let providerBuildResult = providerFactory()

        switch providerBuildResult {
        case let .provider(provider):
            await translate(
                sourceText: sourceText,
                providers: [
                    ResolvedTranslationProvider(
                        id: "default",
                        title: localization.string("openAIClient.providerTitle", defaultValue: "OpenAI 翻译"),
                        provider: provider
                    ),
                ],
                querySource: querySource,
                sessionID: currentSessionID
            )
        case let .providers(providers):
            await translate(
                sourceText: sourceText,
                providers: providers,
                querySource: querySource,
                sessionID: currentSessionID
            )
        case let .missing(message):
            snapshot = TranslatorPanelSnapshot(
                phase: .error(.missingConfiguration),
                sourceText: sourceText,
                languageSelection: snapshot.languageSelection,
                translation: nil,
                providerResults: providerBuildResult.waitingProviderResults(localization: localization),
                errorMessage: message,
                querySource: querySource,
                captureStage: nil
            )
            panelController?.show(snapshot: snapshot)
        }
    }

    private func translate(
        sourceText: String,
        providers: [ResolvedTranslationProvider],
        querySource: TranslatorQuerySource?,
        sessionID currentSessionID: UUID
    ) async {
        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        let languageSelection = AutomaticLanguageSelector(
            preferredPair: languagePreferenceStore.loadPair()
        ).select(text: sourceText)
        let initialProviderResults = providers.map {
            TranslatorProviderResult(
                id: $0.id,
                providerTitle: $0.title,
                phase: $0.provider == nil ? .error : .translating,
                translation: nil,
                errorMessage: $0.errorMessage
            )
        }

        snapshot = TranslatorPanelSnapshot(
            phase: .translating,
            sourceText: sourceText,
            languageSelection: languageSelection,
            translation: nil,
            providerResults: initialProviderResults,
            errorMessage: nil,
            querySource: querySource,
            captureStage: nil
        )
        panelController?.show(snapshot: snapshot)

        guard providers.contains(where: { $0.provider != nil }) else {
            guard !Task.isCancelled, sessionID == currentSessionID else { return }
            finishProviderBatch(
                sourceText: sourceText,
                languageSelection: languageSelection,
                querySource: querySource,
                sessionID: currentSessionID
            )
            return
        }

        let localization = self.localization
        await withTaskGroup(of: ProviderTranslationOutcome.self) { group in
            for resolvedProvider in providers {
                guard let provider = resolvedProvider.provider else {
                    continue
                }

                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let translation = try await provider.translate(
                            text: sourceText,
                            languageSelection: languageSelection
                        )
                        return ProviderTranslationOutcome(
                            providerID: resolvedProvider.id,
                            translation: translation,
                            errorMessage: nil
                        )
                    } catch is CancellationError {
                        return ProviderTranslationOutcome(
                            providerID: resolvedProvider.id,
                            translation: nil,
                            errorMessage: nil
                        )
                    } catch {
                        TranslatorLog.provider.error("translation failed")
                        return ProviderTranslationOutcome(
                            providerID: resolvedProvider.id,
                            translation: nil,
                            errorMessage: Self.userFacingMessage(for: error, localization: localization)
                        )
                    }
                }
            }

            for await outcome in group {
                guard !Task.isCancelled, sessionID == currentSessionID else {
                    group.cancelAll()
                    return
                }

                apply(outcome)
                panelController?.show(snapshot: snapshot)
            }
        }

        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        finishProviderBatch(
            sourceText: sourceText,
            languageSelection: languageSelection,
            querySource: querySource,
            sessionID: currentSessionID
        )
    }

    private func setError(
        _ error: TranslatorPanelError,
        sourceText: String?,
        languageSelection: TranslatorLanguageSelection?,
        providerResults: [TranslatorProviderResult] = [],
        querySource: TranslatorQuerySource? = nil
    ) {
        snapshot = TranslatorPanelSnapshot(
            phase: .error(error),
            sourceText: sourceText,
            languageSelection: languageSelection,
            translation: nil,
            providerResults: providerResults,
            errorMessage: error.message(localization: localization),
            querySource: querySource,
            captureStage: nil
        )
    }

    private func apply(_ outcome: ProviderTranslationOutcome) {
        guard let index = snapshot.providerResults.firstIndex(where: { $0.id == outcome.providerID }) else {
            return
        }

        if let translation = outcome.translation {
            snapshot.providerResults[index].phase = .success
            snapshot.providerResults[index].translation = translation
            snapshot.providerResults[index].errorMessage = nil
            if snapshot.translation == nil {
                snapshot.translation = translation
            }
        } else if let errorMessage = outcome.errorMessage {
            snapshot.providerResults[index].phase = .error
            snapshot.providerResults[index].translation = nil
            snapshot.providerResults[index].errorMessage = errorMessage
        }
    }

    private func finishProviderBatch(
        sourceText: String,
        languageSelection: TranslatorLanguageSelection,
        querySource: TranslatorQuerySource?,
        sessionID currentSessionID: UUID
    ) {
        let firstSuccess = snapshot.providerResults.first { $0.phase == .success }?.translation
        snapshot.translation = firstSuccess

        if let firstSuccess {
            snapshot = TranslatorPanelSnapshot(
                phase: .success,
                sourceText: sourceText,
                languageSelection: languageSelection,
                translation: firstSuccess,
                providerResults: snapshot.providerResults,
                errorMessage: nil,
                querySource: querySource,
                captureStage: nil
            )
        } else {
            let message = snapshot.providerResults.compactMap(\.errorMessage).first
                ?? localization.string("openAIClient.error.requestFailed", defaultValue: "请求失败，请稍后重试")
            snapshot = TranslatorPanelSnapshot(
                phase: .error(.requestFailed(message)),
                sourceText: sourceText,
                languageSelection: languageSelection,
                translation: nil,
                providerResults: snapshot.providerResults,
                errorMessage: message,
                querySource: querySource,
                captureStage: nil
            )
        }
        panelController?.show(snapshot: snapshot)
    }

    private func translateOrShowConfigurationError(
        sourceText: String,
        querySource: TranslatorQuerySource,
        providerBuildResult: TranslatorProviderBuildResult,
        providerResults: [TranslatorProviderResult],
        sessionID currentSessionID: UUID
    ) async {
        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        switch providerBuildResult {
        case let .provider(provider):
            await translate(
                sourceText: sourceText,
                providers: [
                    ResolvedTranslationProvider(
                        id: "default",
                        title: localization.string("openAIClient.providerTitle", defaultValue: "OpenAI 翻译"),
                        provider: provider
                    ),
                ],
                querySource: querySource,
                sessionID: currentSessionID
            )
        case let .providers(providers):
            await translate(
                sourceText: sourceText,
                providers: providers,
                querySource: querySource,
                sessionID: currentSessionID
            )
        case let .missing(message):
            snapshot = TranslatorPanelSnapshot(
                phase: .error(.missingConfiguration),
                sourceText: sourceText,
                languageSelection: nil,
                translation: nil,
                providerResults: providerResults,
                errorMessage: message,
                querySource: querySource,
                captureStage: nil
            )
            panelController?.show(snapshot: snapshot)
        }
    }

    private static func panelError(for error: ScreenshotCaptureError) -> TranslatorPanelError {
        switch error {
        case .screenRecordingPermissionRequired:
            return .screenRecordingPermissionRequired
        case .cancelled:
            return .screenshotCancelled
        case .regionTooSmall:
            return .screenshotRegionTooSmall
        case .noScreen, .screenshotFailed:
            return .screenshotFailed
        }
    }

    private static func panelError(forOCR error: Error, localization: PluginLocalization) -> TranslatorPanelError {
        if let ocrError = error as? OCRTextRecognitionError {
            switch ocrError {
            case .emptyResult:
                return .missingOCRText
            case .invalidImage:
                return .screenshotFailed
            case let .requestFailed(message):
                return .requestFailed(userFacingOCRMessage(message, localization: localization))
            }
        }

        return .requestFailed(userFacingOCRMessage(error.localizedDescription, localization: localization))
    }

    private static func userFacingOCRMessage(_ message: String, localization: PluginLocalization) -> String {
        if message == OCRTextRecognitionError.invalidImage.errorDescription {
            return localization.string("ocr.error.invalidImage", defaultValue: "无法读取截图。")
        }
        if message == OCRTextRecognitionError.emptyResult.errorDescription {
            return localization.string("ocr.error.emptyResult", defaultValue: "截图中没有识别到文字。")
        }
        return message
    }

    nonisolated private static func userFacingMessage(
        for error: Error,
        localization: PluginLocalization
    ) -> String {
        if let error = error as? OpenAICompatibleClientError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? OpenAICompatibleConfigurationError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? TranslationPromptRendererError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? OpenAICompatibleSecretStoreError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? TranslatorProviderProfileValidationError {
            return error.errorDescription(localization: localization)
        }
        return error.localizedDescription
    }

    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func speak(_ text: String?, language: TranslatorLanguage?) {
        guard let text, !text.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        if let language, let voice = AVSpeechSynthesisVoice(language: language.speechLanguageCode) {
            utterance.voice = voice
        }
        speechSynthesizer.speak(utterance)
    }
}
