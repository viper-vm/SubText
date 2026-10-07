import SwiftUI
import UIKit

struct LineDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let line: LyricLine
    let record: SongRecord

    var body: some View {
        let gloss = model.record?.id == record.id ? model.record?.translation?.glosses[line.id] : record.translation?.glosses[line.id]
        let roman = gloss?.romanization ?? model.localRoman[line.id]
        NavigationStack {
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
                            UIPasteboard.general.string = [line.text, gloss?.translation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
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
