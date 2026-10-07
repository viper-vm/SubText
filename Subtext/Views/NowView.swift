import AuthenticationServices
import SwiftUI
import UIKit

struct NowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showSearch = false
    @State private var showPaste = false

    var body: some View {
        NavigationStack {
            Group {
                if let record = model.record {
                    SongView(record: record, showSearch: $showSearch, showPaste: $showPaste)
                } else {
                    EmptyNowView(showSearch: $showSearch)
                }
            }
            .navigationTitle(model.record == nil ? "Subtext" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.following && model.spotify.isConnected {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.followSpotify() } label: {
                            Label("Follow Spotify", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if model.isListening { model.stopListening() } else { await model.startListening() }
                        }
                    } label: {
                        Label(model.isListening ? "Stop listening" : "Listen",
                              systemImage: model.isListening ? "waveform.circle.fill" : "waveform")
                    }
                    .tint(model.isListening ? Color.accentColor : nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") }
                }
                if model.record != nil {
                    ToolbarItem(placement: .topBarTrailing) { moreMenu }
                }
            }
            .sheet(isPresented: $showSearch) { SearchView() }
            .sheet(isPresented: $showPaste) { PasteLyricsView() }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { model.translateIfNeeded(force: true) } label: { Label("Translate again", systemImage: "arrow.clockwise") }
            Button { showPaste = true } label: { Label("Paste lyrics", systemImage: "doc.on.clipboard") }
            if let id = model.record?.track.spotifyID, let url = URL(string: "https://open.spotify.com/track/\(id)") {
                Button { openURL(url) } label: { Label("Open in Spotify", systemImage: "arrow.up.right.square") }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}

// MARK: - Song

struct SongView: View {
    @Environment(AppModel.self) private var model
    let record: SongRecord
    @Binding var showSearch: Bool
    @Binding var showPaste: Bool

    @AppStorage(Prefs.Key.showRomanization) private var showRoman = true
    @AppStorage(Prefs.Key.showTranslation) private var showTranslation = true
    @AppStorage(Prefs.Key.showNotes) private var showNotes = true
    @State private var autoFollow = true
    @State private var detail: LyricLine?
    @State private var detailAsks = false
    @State private var detailQuestion: String?

    private static let anchor = UnitPoint(x: 0.5, y: 0.32)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SongHeader(record: record)
                    StatusBanner(showSearch: $showSearch, showPaste: $showPaste)
                    if let about = record.translation?.about, !about.isEmpty {
                        AboutCard(text: about)
                    }
                    if let lyrics = record.lyrics, !lyrics.lines.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(lyrics.lines) { line in
                                LineRow(line: line,
                                        gloss: record.translation?.glosses[line.id],
                                        localRoman: model.localRoman[line.id],
                                        state: state(of: line),
                                        showRoman: showRoman, showTranslation: showTranslation, showNotes: showNotes)
                                    .id(line.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if !line.isBreak { open(line, asking: false) } }
                                    .contextMenu {
                                        if !line.isBreak {
                                            Button { open(line, asking: true) } label: {
                                                Label("Ask about this line", systemImage: "questionmark.bubble")
                                            }
                                            Button {
                                                let translation = record.translation?.glosses[line.id]?.translation
                                                UIPasteboard.general.string = [line.text, translation].compactMap { $0 }
                                                    .filter { !$0.isEmpty }.joined(separator: "\n")
                                            } label: {
                                                Label("Copy", systemImage: "doc.on.doc")
                                            }
                                        }
                                    }
                            }
                        }
                        Text("Lyrics from LRCLIB")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { autoFollow = false }
            }
            .onChange(of: model.currentLine) { _, line in
                guard autoFollow, let line else { return }
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: Self.anchor) }
            }
            .onChange(of: record.id) {
                autoFollow = true
                proxy.scrollTo(-1, anchor: .top)
            }
            .overlay(alignment: .bottom) {
                PlaybackBar(autoFollow: $autoFollow) { line in
                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: Self.anchor) }
                }
            }
        }
        .onChange(of: model.detailRequest) { _, request in
            guard let request, let line = record.lyrics?.lines.first(where: { $0.id == request.lineID }) else { return }
            model.detailRequest = nil
            open(line, asking: request.ask, question: request.question)
        }
        .sheet(item: $detail) { line in
            LineDetailSheet(line: line, record: record, startAsking: detailAsks, autoQuestion: detailQuestion)
        }
    }

    private func open(_ line: LyricLine, asking: Bool, question: String? = nil) {
        detailAsks = asking
        detailQuestion = question
        detail = line
    }

    private func state(of line: LyricLine) -> LineRow.LineState {
        guard let current = model.currentLine else { return .neutral }
        if line.id == current { return .current }
        return line.id < current ? .past : .upcoming
    }
}

struct SongHeader: View {
    @Environment(AppModel.self) private var model
    let record: SongRecord

    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: record.track.artworkURL, size: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.track.title).font(.title3.bold()).lineLimit(2)
                if !record.track.artist.isEmpty {
                    Text(record.track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    sourceChip
                    if let languages { Chip(text: languages, systemImage: "globe") }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .id(-1)
    }

    @ViewBuilder private var sourceChip: some View {
        if model.following && model.source == .spotify {
            let paused = model.spotifyNow.map { !$0.isPlaying } ?? false
            Chip(text: paused ? "Paused on Spotify" : "Spotify", systemImage: "dot.radiowaves.left.and.right", tint: .spotifyGreen)
        } else {
            switch model.source {
            case .listening: Chip(text: model.isListening ? "Listening" : "Heard nearby", systemImage: "waveform", tint: .accentColor)
            case .shortcut: Chip(text: "Shazam", systemImage: "shazam.logo")
            case .history: Chip(text: "History", systemImage: "clock")
            case .pasted: Chip(text: "Pasted", systemImage: "doc.on.clipboard")
            default: Chip(text: "Search", systemImage: "magnifyingglass")
            }
        }
    }

    private var languages: String? {
        let source = record.translation?.sourceLanguageName ?? model.detected?.name
        guard let source else { return nil }
        let target = TargetLanguage.name(for: record.translation?.targetLanguage ?? Prefs.targetLanguage)
        return LanguageTools.sameLanguage(source, target) ? source : "\(source) → \(target)"
    }
}

struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    @Binding var showSearch: Bool
    @Binding var showPaste: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = model.listenMessage {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.footnote)
                        if model.isListening {
                            Button("Stop listening") { model.stopListening() }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            lyricsStatus
            translationStatus
            if model.lyricsState == .loaded, let lyrics = model.record?.lyrics, !lyrics.synced, !lyrics.instrumental {
                Label("These lyrics have no timing, so they won't scroll with the song.", systemImage: "clock.badge.questionmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var lyricsStatus: some View {
        switch model.lyricsState {
        case .loading:
            Card { HStack(spacing: 10) { ProgressView(); Text("Finding lyrics…") } }
        case .notFound:
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No lyrics found for this song.").font(.subheadline.weight(.semibold))
                    Text("Try searching with a different spelling, or paste the lyrics yourself.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Search") { showSearch = true }.buttonStyle(.bordered)
                        Button("Paste lyrics") { showPaste = true }.buttonStyle(.bordered)
                    }
                }
            }
        case .failed(let message):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.footnote)
                    Button("Try again") { model.retryLyrics() }.buttonStyle(.bordered)
                }
            }
        case .idle, .loaded:
            EmptyView()
        }
    }

    @ViewBuilder private var translationStatus: some View {
        switch model.translateState {
        case .working(let done, let total, let engine):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    if engine == .claude {
                        Text("Translating with Claude… \(done) of \(total) lines").font(.footnote)
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                    } else {
                        HStack(spacing: 10) { ProgressView(); Text("Translating on this iPhone…").font(.footnote) }
                    }
                }
            }
        case .needsKey(let message):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.footnote)
                    Button("Open Settings") { model.selectedTab = .settings }.buttonStyle(.bordered)
                }
            }
        case .failed(let message):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.footnote)
                    Button("Try again") { model.translateIfNeeded(force: true) }.buttonStyle(.bordered)
                }
            }
        case .skipped(let message):
            HStack {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if model.record?.lyrics?.instrumental != true {
                    Button("Translate anyway") { model.translateIfNeeded(force: true) }.font(.footnote)
                }
            }
        case .idle, .done:
            EmptyView()
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AboutCard: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("What it's about", systemImage: "text.quote").font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text(text).font(.subheadline).lineLimit(expanded ? nil : 3)
            }
        }
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }
}

struct LineRow: View {
    enum LineState { case neutral, past, current, upcoming }

    let line: LyricLine
    let gloss: LineGloss?
    let localRoman: String?
    let state: LineState
    let showRoman: Bool
    let showTranslation: Bool
    let showNotes: Bool

    var body: some View {
        if line.isBreak {
            Image(systemName: "music.note")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .opacity(state == .current ? 1 : 0.6)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(line.text)
                    .font(.title3.weight(state == .current ? .bold : .semibold))
                    .foregroundStyle(state == .upcoming || state == .past ? HierarchicalShapeStyle.secondary : .primary)
                if showRoman, let roman {
                    Text(roman).font(.callout).italic().foregroundStyle(.secondary)
                }
                if showTranslation, let translation = gloss?.translation, !translation.isEmpty {
                    Text(translation).font(.body.weight(.medium)).foregroundStyle(Color.accentColor)
                }
                if showNotes, let note = gloss?.note, !note.isEmpty {
                    Label(note, systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(state == .past ? 0.45 : 1)
            .animation(.easeOut(duration: 0.25), value: state)
        }
    }

    private var roman: String? {
        let value = gloss?.romanization ?? localRoman
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct PlaybackBar: View {
    @Environment(AppModel.self) private var model
    @Binding var autoFollow: Bool
    let scrollTo: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if !autoFollow, let line = model.currentLine {
                Button {
                    autoFollow = true
                    scrollTo(line)
                } label: {
                    Label("Current line", systemImage: "arrow.down.to.line")
                }
            }
            if let line = model.currentLine,
               model.record?.lyrics?.lines.first(where: { $0.id == line })?.isBreak == false {
                Button { model.requestDetail(lineID: line, ask: true) } label: {
                    Label("Ask", systemImage: "questionmark.bubble")
                }
            }
            if !model.following, model.record?.lyrics?.synced == true {
                Button {
                    if model.isPlayingAlong { model.pausePlayAlong() } else { model.startPlayAlong(from: nil) }
                } label: {
                    Label(model.isPlayingAlong ? "Pause" : "Play along",
                          systemImage: model.isPlayingAlong ? "pause.fill" : "play.fill")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .padding(.bottom, 14)
        .animation(.snappy, value: autoFollow)
    }
}

// MARK: - Nothing playing

struct EmptyNowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Binding var showSearch: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Understand every song").font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                if !model.spotify.isConnected {
                    Button {
                        Task { await model.connectSpotify(using: webAuthenticationSession) }
                    } label: {
                        Label("Connect Spotify", systemImage: "link").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.spotifyGreen)
                }
                Button { showSearch = true } label: {
                    Label("Search for a song", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    Task {
                        if model.isListening { model.stopListening() } else { await model.startListening() }
                    }
                } label: {
                    Label(model.isListening ? "Stop listening" : "Listen to music around me",
                          systemImage: model.isListening ? "stop.circle" : "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 8)
            if model.isListening {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Listening for music…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let message = model.listenMessage {
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if let message = model.spotifyMessage {
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var subtitle: String {
        if !model.spotify.isConnected {
            return "Connect Spotify and the lyrics of whatever you play appear here with a translation under every line."
        }
        if model.spotifyNow == nil {
            return "Play something on Spotify and it shows up here."
        }
        return "Loading…"
    }
}
