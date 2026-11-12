import Foundation

/// Единственный адрес и формат запроса для всех функций Groq.
public enum GroqChat {
    public static let model = "openai/gpt-oss-20b"
    public static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    public static let maxRequestBytes = 16_000
    public static let maxCompletionTokens = 3_072
    public static let maxResponseBytes = 32_000

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    enum Output {
        case text
        case jsonObject
        case browserSearch
    }

    static func requestBody(messages: [[String: Any]], output: Output = .text) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "reasoning_effort": "low",
            "include_reasoning": false,
            "max_completion_tokens": maxCompletionTokens,
            "service_tier": "on_demand",
            "stream": false,
            "messages": messages,
        ]
        switch output {
        case .text:
            break
        case .jsonObject:
            payload["response_format"] = ["type": "json_object"]
        case .browserSearch:
            payload["tools"] = [["type": "browser_search"]]
            payload["tool_choice"] = "required"
            payload["citation_options"] = "enabled"
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        guard data.count <= maxRequestBytes else { throw DraftPolishError.requestTooLarge }
        return data
    }

    static func request(body: Data, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DraftPolishError.noKey }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    static func send(_ request: URLRequest, using session: URLSession, maxBytes: Int = maxResponseBytes) async throws -> Data {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw DraftPolishError.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DraftPolishError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw DraftPolishError.http(http.statusCode) }
        guard data.count <= maxBytes else { throw DraftPolishError.responseTooLarge }
        return data
    }

    public static func extractText(_ data: Data) throws -> String {
        try extractText(data) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    static func extractText(_ data: Data, cleanOutput: (String) -> String) throws -> String {
        let message = try responseMessage(data)
        let text = cleanOutput(message["content"] as? String ?? "")
        guard !text.isEmpty else { throw DraftPolishError.badResponse }
        return text
    }

    static func responseMessage(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw DraftPolishError.badResponse
        }
        if choice["finish_reason"] as? String == "length" {
            throw DraftPolishError.truncatedResponse
        }
        // Встроенный поиск исполняет Groq. Клиент не выполняет вызовы инструментов.
        if let calls = message["tool_calls"], !(calls is NSNull), (calls as? [Any])?.isEmpty != true {
            throw DraftPolishError.badResponse
        }
        return message
    }
    public static func stripCodeFence(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "^```[A-Za-z]*\\n?", with: "", options: .regularExpression)
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
