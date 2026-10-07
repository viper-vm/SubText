import Foundation

/// Prompts for asking Claude about one lyric line.
enum LinePrompt {
    static let suggestions = [
        "Explain it word by word",
        "What does it really mean?",
        "Any slang or references?",
        "Explain the grammar",
        "How do I pronounce it?",
    ]

    static func system(target: String) -> String {
        """
        You help someone understand a song they are listening to. They are asking about one line of its lyrics.

        Answer in \(target). Be clear and brief: usually two to five sentences, or a short list when breaking a line down word by word. Explain meaning, word choice, grammar, slang, idioms, and cultural, religious or historical references, and how words are pronounced when asked. Quote only the words you are explaining, never whole lines or verses. Write plain text without headings; short lists are fine. If you are not sure about something, say so.
        """
    }

    /// The first question carries the song and the lines around the one being asked about.
    static func firstMessage(track: Track, lyrics: Lyrics, line: LyricLine, translation: String?, about: String?,
                             question: String) -> String {
        var text = "Song: \(track.title)" + (track.artist.isEmpty ? "" : " by \(track.artist)") + "\n"
        if let about, !about.isEmpty { text += "What the song is about: \(about)\n" }

        let words = lyrics.wordLines
        if let index = words.firstIndex(where: { $0.id == line.id }) {
            text += "\nLines around the one I'm asking about (marked »):\n"
            for nearby in words[max(0, index - 3)...min(words.count - 1, index + 3)] {
                text += (nearby.id == line.id ? "» " : "  ") + nearby.text + "\n"
            }
        } else {
            text += "\nThe line I'm asking about: \(line.text)\n"
        }
        if let translation, !translation.isEmpty { text += "\nThe app translates that line as: \(translation)\n" }
        text += "\nMy question: \(question)"
        return text
    }

    /// The whole conversation about a line: earlier questions and answers, then the new question.
    static func turns(history: [LineQuestion], newQuestion: String, firstMessage: (String) -> String) -> [ClaudeTurn] {
        var turns: [ClaudeTurn] = []
        let questions = history.map(\.question) + [newQuestion]
        for (index, question) in questions.enumerated() {
            turns.append(ClaudeTurn(role: .user, text: index == 0 ? firstMessage(question) : question))
            if index < history.count { turns.append(ClaudeTurn(role: .assistant, text: history[index].answer)) }
        }
        return turns
    }
}
