import Foundation

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
        let request: URLRequest
        do {
            request = try ClaudeAPI.request(
                apiKey: apiKey, model: model, system: Self.systemPrompt(target: targetName),
                turns: [ClaudeTurn(role: .user, text: Self.userPrompt(track: track, lines: lines, target: targetName))],
                maxTokens: 16000)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var buffer = ""
                    for try await text in ClaudeAPI.streamText(request) {
                        buffer += text
                        while let newline = buffer.firstIndex(of: "\n") {
                            let row = String(buffer[..<newline])
                            buffer.removeSubrange(...newline)
                            if let event = Self.parse(row) { continuation.yield(event) }
                        }
                    }
                    if let event = Self.parse(buffer) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
}
