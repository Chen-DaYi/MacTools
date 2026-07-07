import Foundation
import MacToolsPluginKit

enum TranslatorQuerySource: Equatable, Sendable {
    case selectedText
    case screenshot

    var sourceTitle: String {
        switch self {
        case .selectedText:
            return "selectedText"
        case .screenshot:
            return "screenshot"
        }
    }
}

enum TranslatorCaptureStage: Equatable, Sendable {
    case selectedText
    case screenshotRegion
    case ocr

    var placeholderKey: String {
        switch self {
        case .selectedText:
            return "panel.sourcePlaceholder.capturing"
        case .screenshotRegion:
            return "panel.sourcePlaceholder.screenshotRegion"
        case .ocr:
            return "panel.sourcePlaceholder.ocr"
        }
    }
}

enum TranslatorPanelPhase: Equatable, Sendable {
    case idle
    case capturing
    case translating
    case success
    case error(TranslatorPanelError)
}

enum TranslatorPanelError: Equatable, Sendable {
    case missingSelection
    case missingOCRText
    case missingConfiguration
    case permissionRequired
    case screenRecordingPermissionRequired
    case screenshotCancelled
    case screenshotRegionTooSmall
    case screenshotFailed
    case requestFailed(String)

    var message: String {
        message()
    }

    func message(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .missingSelection:
            return localization.string("panelError.missingSelection", defaultValue: "未找到选中文本")
        case .missingOCRText:
            return localization.string("panelError.missingOCRText", defaultValue: "截图中没有识别到文字")
        case .missingConfiguration:
            return localization.string("panelError.missingConfiguration", defaultValue: "请先配置 OpenAI")
        case .permissionRequired:
            return localization.string("panelError.permissionRequired", defaultValue: "需要辅助功能授权")
        case .screenRecordingPermissionRequired:
            return localization.string("panelError.screenRecordingPermissionRequired", defaultValue: "需要屏幕录制授权")
        case .screenshotCancelled:
            return localization.string("panelError.screenshotCancelled", defaultValue: "已取消截图")
        case .screenshotRegionTooSmall:
            return localization.string("panelError.screenshotRegionTooSmall", defaultValue: "截图区域太小")
        case .screenshotFailed:
            return localization.string("panelError.screenshotFailed", defaultValue: "截图失败")
        case let .requestFailed(message):
            return message
        }
    }
}

struct TranslatorPanelSnapshot: Equatable, Sendable {
    var phase: TranslatorPanelPhase
    var sourceText: String?
    var languageSelection: TranslatorLanguageSelection?
    var translation: TranslationResult?
    var providerResults: [TranslatorProviderResult] = []
    var errorMessage: String?
    var querySource: TranslatorQuerySource? = nil
    var captureStage: TranslatorCaptureStage? = nil

    static let idle = TranslatorPanelSnapshot(
        phase: .idle,
        sourceText: nil,
        languageSelection: nil,
        translation: nil,
        providerResults: [],
        errorMessage: nil,
        querySource: nil,
        captureStage: nil
    )
}

enum TranslatorPanelAction: Equatable, Sendable {
    case retry
    case close
    case copySource
    case copyTranslation
    case copyProviderTranslation(String)
    case speakSource
    case speakTranslation
    case openSettings
}

enum TranslatorProviderResultPhase: Equatable, Sendable {
    case waiting
    case translating
    case success
    case error
}

struct TranslatorProviderResult: Equatable, Identifiable, Sendable {
    var id: String
    var providerTitle: String
    var phase: TranslatorProviderResultPhase
    var translation: TranslationResult?
    var errorMessage: String?

    var text: String? {
        translation?.text
    }
}

struct ResolvedTranslationProvider: Sendable {
    var id: String
    var title: String
    var provider: (any TranslationProviding)?
    var errorMessage: String?

    init(
        id: String,
        title: String,
        provider: any TranslationProviding
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.errorMessage = nil
    }

    init(
        id: String,
        title: String,
        errorMessage: String
    ) {
        self.id = id
        self.title = title
        self.provider = nil
        self.errorMessage = errorMessage
    }
}

enum TranslatorProviderBuildResult {
    case provider(any TranslationProviding)
    case providers([ResolvedTranslationProvider])
    case missing(message: String)

    var resolvedProviders: [ResolvedTranslationProvider]? {
        resolvedProviders()
    }

    func resolvedProviders(
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> [ResolvedTranslationProvider]? {
        switch self {
        case let .provider(provider):
            return [
                ResolvedTranslationProvider(
                    id: "default",
                    title: localization.string("openAIClient.providerTitle", defaultValue: "OpenAI 翻译"),
                    provider: provider
                ),
            ]
        case let .providers(providers):
            return providers
        case .missing:
            return nil
        }
    }

    var waitingProviderResults: [TranslatorProviderResult] {
        waitingProviderResults()
    }

    func waitingProviderResults(
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> [TranslatorProviderResult] {
        switch self {
        case .provider:
            return [
                TranslatorProviderResult(
                    id: "default",
                    providerTitle: localization.string("openAIClient.providerTitle", defaultValue: "OpenAI 翻译"),
                    phase: .waiting,
                    translation: nil,
                    errorMessage: nil
                ),
            ]
        case let .providers(providers):
            return providers.map {
                TranslatorProviderResult(
                    id: $0.id,
                    providerTitle: $0.title,
                    phase: .waiting,
                    translation: nil,
                    errorMessage: $0.errorMessage
                )
            }
        case .missing:
            return []
        }
    }
}
