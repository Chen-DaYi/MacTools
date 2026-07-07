import Foundation
import MacToolsPluginKit

struct OpenAICompatibleClient: Sendable {
    private let httpClient: any TranslatorHTTPClient
    private let timeout: TimeInterval
    private let localization: PluginLocalization

    init(
        httpClient: any TranslatorHTTPClient = URLSession.shared,
        timeout: TimeInterval = 30,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.localization = localization
    }

    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection,
        configuration: OpenAICompatibleConfiguration,
        apiKey: String
    ) async throws -> TranslationResult {
        let sourceLanguageName = languageSelection.source?.promptName ?? "Auto Detect"
        let targetLanguageName = languageSelection.target.promptName
        let prompt = try TranslationPromptRenderer(template: configuration.promptTemplate).render(
            text: text,
            sourceLanguageName: sourceLanguageName,
            targetLanguageName: targetLanguageName
        )
        let requestBody = OpenAIChatCompletionsRequest(
            model: configuration.normalizedModel,
            messages: [
                OpenAIChatCompletionsRequest.Message(role: "user", content: prompt),
            ],
            temperature: 0.2,
            stream: false
        )

        var request = URLRequest(
            url: try configuration.endpointURL(),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: HTTPURLResponse

        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let error as OpenAICompatibleClientError {
            throw error
        } catch {
            // Log only the transport-level error category; never log headers, API keys, or bodies.
            TranslatorLog.provider.error("translation request transport error")
            throw OpenAICompatibleClientError.requestFailed
        }

        guard (200 ... 299).contains(response.statusCode) else {
            TranslatorLog.provider.error("translation request failed with status \(response.statusCode, privacy: .public)")

            if response.statusCode == 401 || response.statusCode == 403 {
                throw OpenAICompatibleClientError.unauthorized
            }

            throw OpenAICompatibleClientError.requestFailed
        }

        let content = try decodeContent(from: data)

        return TranslationResult(
            providerTitle: localization.string("openAIClient.providerTitle", defaultValue: "OpenAI 翻译"),
            text: content,
            sourceText: text,
            languageSelection: languageSelection
        )
    }

    private func decodeContent(from data: Data) throws -> String {
        let response: OpenAIChatCompletionsResponse

        do {
            response = try JSONDecoder().decode(OpenAIChatCompletionsResponse.self, from: data)
        } catch {
            throw OpenAICompatibleClientError.parseFailed
        }

        guard let content = response.choices.first?.message.content else {
            throw OpenAICompatibleClientError.parseFailed
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw OpenAICompatibleClientError.emptyResponse
        }

        return trimmedContent
    }
}

enum OpenAICompatibleClientError: Error, Equatable, Sendable {
    case invalidResponse
    case requestFailed
    case unauthorized
    case emptyResponse
    case parseFailed
}

extension OpenAICompatibleClientError: LocalizedError {
    var errorDescription: String? {
        errorDescription()
    }

    func errorDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .invalidResponse, .requestFailed:
            return localization.string("openAIClient.error.requestFailed", defaultValue: "请求失败，请稍后重试")
        case .unauthorized:
            return localization.string("openAIClient.error.unauthorized", defaultValue: "API Key 无效或无权限")
        case .emptyResponse:
            return localization.string("openAIClient.error.emptyResponse", defaultValue: "响应为空")
        case .parseFailed:
            return localization.string("openAIClient.error.parseFailed", defaultValue: "无法解析翻译结果")
        }
    }
}

private struct OpenAIChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
}

private struct OpenAIChatCompletionsResponse: Decodable {
    struct Message: Decodable {
        let content: String
    }

    struct Choice: Decodable {
        let message: Message
    }

    let choices: [Choice]
}
