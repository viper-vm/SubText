import Foundation

enum ClaudeError: LocalizedError {
    case api(Int, String)
    case refused
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .api(401, _): "Claude rejected the API key. Check it in Settings."
        case .api(402, let message), .api(403, let message): "Claude refused the request: \(message)"
        case .api(429, _): "Claude is busy or your usage limit was reached. Try again in a minute."
        case .api(let code, let message): "Claude error \(code): \(message)"
        case .refused: "Claude declined this request."
        case .truncated: "Claude's reply was cut off. Try again, or pick a different model in Settings."
        case .badResponse: "Claude's reply couldn't be read."
        }
    }
}

struct ClaudeTurn: Equatable {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

/// Raw HTTP calls to the Claude Messages API (there is no official Anthropic SDK for Swift).
enum ClaudeAPI {
    static var endpoint: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SUBTEXT_CLAUDE_URL"], let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://api.anthropic.com/v1/messages")!
    }

    /// A streaming request. `turns` alternate user and assistant, starting and ending with the user.
    static func request(apiKey: String, model: ClaudeModel, system: String, turns: [ClaudeTurn], maxTokens: Int) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        switch model {
        case .opus, .sonnet:
            // Lyrics need little reasoning; low effort keeps replies quick and cheap.
            body["output_config"] = ["effort": "low"]
            // If a safety classifier declines, the API retries on Anthropic's recommended fallback model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        case .haiku:
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The reply's text, piece by piece as it arrives.
    static func streamText(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
                    guard http.statusCode == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw ClaudeError.api(http.statusCode, errorMessage(data))
                    }
                    var stopReason: String?
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            // Thinking and other block types are skipped; only the answer's text is shown.
                            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                            }
                        case "error":
                            let error = event["error"] as? [String: Any]
                            throw ClaudeError.api(0, error?["message"] as? String ?? "Unknown error")
                        default:
                            break
                        }
                    }
                    if stopReason == "refusal" { throw ClaudeError.refused }
                    if stopReason == "max_tokens" { throw ClaudeError.truncated }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "Unknown error"
    }
}
