import Foundation

enum TranslateError: LocalizedError {
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
        case .refused: "Claude declined to translate this song."
        case .truncated: "The translation was cut off. Try again, or pick a different model."
        case .badResponse: "Claude's reply couldn't be read."
        }
    }
}

/// Streams a line-by-line translation from Claude so lines appear as they arrive.
struct ClaudeTranslator {
    enum Event: Equatable {
        case language(name: String, code: String)
        case gloss(id: Int, LineGloss)
        case about(String)
    }

    let apiKey: String
    let model: ClaudeModel
    let targetName: String

    func stream(track: Track, lines: [LyricLine]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await run(track: track, lines: lines) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static var endpoint: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SUBTEXT_CLAUDE_URL"], let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://api.anthropic.com/v1/messages")!
    }

    private func run(track: Track, lines: [LyricLine], emit: (Event) -> Void) async throws {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            "stream": true,
            "system": Self.systemPrompt(target: targetName),
            "messages": [["role": "user", "content": Self.userPrompt(track: track, lines: lines, target: targetName)]],
        ]
        switch model {
        case .opus, .sonnet:
            // Translation needs little reasoning; low effort keeps it quick and cheap.
            body["output_config"] = ["effort": "low"]
            // If a safety classifier declines, the API retries on Anthropic's recommended fallback model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        case .haiku:
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslateError.badResponse }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw TranslateError.api(http.statusCode, Self.errorMessage(data))
        }

        var buffer = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { continue }
                buffer += text
                while let newline = buffer.firstIndex(of: "\n") {
                    let row = String(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let parsed = Self.parse(row) { emit(parsed) }
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw TranslateError.api(0, error?["message"] as? String ?? "Unknown error")
            default:
                break
            }
        }
        if let parsed = Self.parse(buffer) { emit(parsed) }
        if stopReason == "refusal" { throw TranslateError.refused }
        if stopReason == "max_tokens" { throw TranslateError.truncated }
    }

    // MARK: - Prompt

    static func systemPrompt(target: String) -> String {
        """
        You translate song lyrics line by line for a listener who wants to understand what they are hearing.

        Reply in plain text only, with no markdown and no introduction. Write one record per line, with fields separated by a single tab character, in this order:
        LANG\t<the song's main language, in English>\t<its ISO 639-1 code>
        L\t<line number>\t<translation>\t<romanization>\t<note>
        ABOUT\t<two or three sentences on what the song is about and its mood>

        Write the LANG record first, then one L record for every numbered input line in the same order, then the ABOUT record.

        Rules:
        - Translate into \(target). Give the meaning a fluent listener would take from the line, not a word-for-word gloss, and keep it about as short as the original.
        - Translate repeated lines the same way each time.
        - The romanization shows how the line sounds, in the usual system for its language: Hepburn for Japanese, Revised Romanization for Korean, pinyin with tone marks for Chinese, and everyday phonetic spelling for Hindi, Punjabi, Urdu, Tamil, Telugu and similar languages. Leave it empty when the line is already in Latin letters.
        - Leave the translation empty when a line is already in \(target).
        - Leave the note empty unless the line has an idiom, slang, wordplay, a double meaning, or a cultural, religious or literary reference worth explaining; then explain it in at most 20 words.
        - Never skip, merge or renumber lines, and never put a tab inside a field.
        """
    }

    static func userPrompt(track: Track, lines: [LyricLine], target: String) -> String {
        var text = "Song: \(track.title) by \(track.artist)\nTranslate into: \(target)\n\nLines:\n"
        for line in lines { text += "\(line.id)\t\(line.text)\n" }
        return text
    }

    // MARK: - Parsing

    static func parse(_ raw: String) -> Event? {
        var row = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !row.isEmpty else { return nil }
        row = row.replacingOccurrences(of: "<TAB>", with: "\t")
        var fields = row.components(separatedBy: "\t")
        if fields.count == 1, row.contains(" | ") { fields = row.components(separatedBy: " | ") }
        fields = fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let tag = fields.first?.uppercased() else { return nil }

        switch tag {
        case "LANG" where fields.count >= 2:
            return .language(name: fields[1], code: fields.count > 2 ? fields[2].lowercased() : "")
        case "L" where fields.count >= 3:
            guard let id = Int(fields[1]) else { return nil }
            let romanization = fields.count > 3 ? fields[3] : ""
            let note = fields.count > 4 ? fields[4...].joined(separator: " ").trimmingCharacters(in: .whitespaces) : ""
            return .gloss(id: id, LineGloss(translation: fields[2],
                                            romanization: romanization.isEmpty ? nil : romanization,
                                            note: note.isEmpty ? nil : note))
        case "ABOUT" where fields.count >= 2:
            return .about(fields[1...].joined(separator: " "))
        default:
            return nil
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
