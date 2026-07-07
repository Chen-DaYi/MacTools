import Foundation

protocol TranslatorHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: TranslatorHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse
        }

        return (data, httpResponse)
    }
}
