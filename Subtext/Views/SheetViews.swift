import SwiftUI
import UIKit

struct LineDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let line: LyricLine
    let record: SongRecord
    let startAsking: Bool
    let autoQuestion: String?

    @State private var chat: LineChat
    @State private var draft = ""
    @State private var detent: PresentationDetent
    @FocusState private var inputFocused: Bool
    private let hasKey = Prefs.claudeKey != nil

    init(line: LyricLine, record: SongRecord, startAsking: Bool = false, autoQuestion: String? = nil) {
        self.line = line
        self.record = record
        self.startAsking = startAsking
        self.autoQuestion = autoQuestion
        _chat = State(initialValue: LineChat(record: record, line: line))
        let hasAnswers = !(record.questions?[line.id] ?? []).isEmpty
        _detent = State(initialValue: startAsking || hasAnswers ? .large : .medium)
    }

    var body: some View {
        let current = model.record?.id == record.id ? (model.record ?? record) : record
        let gloss = current.translation?.glosses[line.id]
        let roman = gloss?.romanization ?? model.localRoman[line.id]
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(line.text).font(.title2.bold()).textSelection(.enabled)
                        if let roman, !roman.isEmpty {
                            Text(roman).font(.title3).italic().foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let translation = gloss?.translation, !translation.isEmpty {
                            Text(translation).font(.title3.weight(.medium)).foregroundStyle(Color.accentColor).textSelection(.enabled)
                        }
                        if let note = gloss?.note, !note.isEmpty {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Note", systemImage: "lightbulb").font(.footnote.weight(.semibold))
                                    Text(note).font(.subheadline)
                                }
                            }
                        }
                        HStack {
                            if record.lyrics?.synced == true, line.time != nil, !model.following {
                                Button {
                                    model.startPlayAlong(from: line)
                                    dismiss()
                                } label: {
                                    Label("Play along from here", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Button {
                                UIPasteboard.general.string = [line.text, gloss?.translation].compactMap { $0 }
                                    .filter { !$0.isEmpty }.joined(separator: "\n")
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)

                        Divider().padding(.vertical, 4)
                        askSection
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.streamingAnswer) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat.turns.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: chat.pendingQuestion) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) {
                if hasKey { inputBar }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .task {
            if let autoQuestion {
                chat.ask(autoQuestion, app: model)
            } else if startAsking, hasKey {
                inputFocused = true
            }
        }
        .onDisappear { chat.cancel() }
    }

    @ViewBuilder private var askSection: some View {
        Label("Ask about this line", systemImage: "questionmark.bubble")
            .font(.headline)
        if !hasKey {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask Claude what a word means, why it's said that way, or what it refers to. This needs a Claude API key.")
                        .font(.subheadline)
                    Button("Add a key in Settings") {
                        model.selectedTab = .settings
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            ForEach(chat.turns) { turn in
                AnswerCard(question: turn.question, answer: turn.answer, inProgress: false)
            }
            if let pending = chat.pendingQuestion {
                AnswerCard(question: pending, answer: chat.streamingAnswer, inProgress: chat.isAnswering)
            }
            if let error = chat.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button("Try again") { chat.retry(app: model) }.buttonStyle(.bordered)
                }
            }
            if chat.turns.isEmpty && chat.pendingQuestion == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LinePrompt.suggestions, id: \.self) { suggestion in
                            Button(suggestion) { send(suggestion) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .font(.subheadline)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask anything about this line", text: $draft)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
            Button { send(draft) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isAnswering)
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.isAnswering else { return }
        draft = ""
        detent = .large
        chat.ask(question, app: model)
    }
}

private struct AnswerCard: View {
    let question: String
    let answer: String
    let inProgress: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
            if answer.isEmpty {
                if inProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Asking Claude…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(Self.formatted(answer)).font(.subheadline).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Shows **bold** and *italic* from the answer while keeping its line breaks.
    static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct PasteLyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var title = ""
    @State private var artist = ""
    @State private var newSong = false

    var body: some View {
        NavigationStack {
            Form {
                if let current = model.record, !newSong {
                    Section {
                        LabeledContent("For", value: current.track.title)
                        Button("A different song instead") { newSong = true }
                    }
                } else {
                    Section("Song") {
                        TextField("Title", text: $title)
                        TextField("Artist", text: $artist)
                    }
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 260)
                        .font(.body)
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text("One lyric line per line. Timed lyrics in LRC format ([01:02.30] …) scroll with the song.")
                }
            }
            .navigationTitle("Paste lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let forCurrent = model.record != nil && !newSong
                        model.useLyrics(text: text, title: forCurrent ? "" : title, artist: forCurrent ? "" : artist)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ((model.record == nil || newSong) && title.isEmpty))
                }
            }
        }
    }
}
