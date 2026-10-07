import Foundation
import Observation

/// The questions and answers about one lyric line, shown in that line's sheet.
@MainActor
@Observable
final class LineChat {
    private(set) var turns: [LineQuestion]
    /// The question being answered (or that failed, so it can be retried).
    private(set) var pendingQuestion: String?
    private(set) var streamingAnswer = ""
    private(set) var errorMessage: String?

    var isAnswering: Bool { pendingQuestion != nil && errorMessage == nil }

    @ObservationIgnored private let record: SongRecord
    @ObservationIgnored private let line: LyricLine
    @ObservationIgnored private var task: Task<Void, Never>?

    init(record: SongRecord, line: LyricLine) {
        self.record = record
        self.line = line
        turns = record.questions?[line.id] ?? []
    }

    func ask(_ raw: String, app: AppModel) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering, let apiKey = Prefs.claudeKey, let lyrics = record.lyrics else { return }
        pendingQuestion = question
        streamingAnswer = ""
        errorMessage = nil

        let history = turns
        let record = record
        let line = line
        let translation = app.record?.id == record.id ? app.record?.translation : record.translation
        let target = TargetLanguage.name(for: Prefs.targetLanguage)
        let model = Prefs.claudeModel

        task = Task { [weak self] in
            do {
                let turns = LinePrompt.turns(history: history, newQuestion: question) { first in
                    LinePrompt.firstMessage(track: record.track, lyrics: lyrics, line: line,
                                            translation: translation?.glosses[line.id]?.translation,
                                            about: translation?.about, question: first)
                }
                let request = try ClaudeAPI.request(apiKey: apiKey, model: model, system: LinePrompt.system(target: target),
                                                    turns: turns, maxTokens: 4000)
                for try await text in ClaudeAPI.streamText(request) {
                    self?.streamingAnswer += text
                }
                guard let self else { return }
                let entry = LineQuestion(question: question,
                                         answer: self.streamingAnswer.trimmingCharacters(in: .whitespacesAndNewlines))
                self.turns.append(entry)
                self.pendingQuestion = nil
                self.streamingAnswer = ""
                app.saveQuestion(entry, lineID: line.id, songKey: record.id)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func retry(app: AppModel) {
        guard let question = pendingQuestion else { return }
        pendingQuestion = nil
        errorMessage = nil
        ask(question, app: app)
    }

    /// Stops a reply in progress when the sheet closes; nothing is saved for it.
    func cancel() {
        task?.cancel()
        task = nil
        if errorMessage == nil {
            pendingQuestion = nil
            streamingAnswer = ""
        }
    }
}
