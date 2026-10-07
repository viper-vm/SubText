import AuthenticationServices
import Foundation
import Observation
import SwiftUI
import Translation

enum AppTab: Hashable { case now, history, settings }

enum LyricsState: Equatable {
    case idle, loading, loaded, notFound
    case failed(String)
}

enum TranslateState: Equatable {
    case idle
    case working(done: Int, total: Int, engine: TranslationEngine)
    case done
    case skipped(String)
    case needsKey(String)
    case failed(String)
}

/// A clock for "where are we in the song", fed by Spotify or by the play-along button.
struct PlaybackClock {
    private(set) var active = false
    private(set) var playing = false
    private var position0: TimeInterval = 0
    private var date0 = Date()

    func position(at date: Date = Date()) -> TimeInterval {
        playing ? position0 + date.timeIntervalSince(date0) : position0
    }

    /// When the song started, at its current pace. Stays the same between re-syncs (rounded to 0.1 s).
    var songStart: Date? {
        guard active, playing else { return nil }
        let start = date0.addingTimeInterval(-position0).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (start * 10).rounded() / 10)
    }

    mutating func set(position: TimeInterval, at date: Date = Date(), playing: Bool) {
        position0 = position
        date0 = date
        self.playing = playing
        active = true
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var selectedTab: AppTab = .now

    /// true: show whatever Spotify plays. false: a song picked by search, history or the Shazam shortcut.
    private(set) var following = true
    private(set) var record: SongRecord?
    private(set) var source: SongSource = .spotify
    private(set) var lyricsState: LyricsState = .idle
    private(set) var translateState: TranslateState = .idle
    private(set) var detected: DetectedLanguage?
    /// On-device romanization per line id, used when the translation has none.
    private(set) var localRoman: [Int: String] = [:]
    private(set) var currentLine: Int?
    private(set) var spotifyNow: SpotifyNowPlaying?
    private(set) var spotifyMessage: String?
    private(set) var isPlayingAlong = false
    /// Drives `.translationTask` on the root view (Apple's translator only runs inside a view).
    var appleConfig: TranslationSession.Configuration?

    let spotify = SpotifyAuth()
    let store = SongStore()

    @ObservationIgnored private var clock = PlaybackClock()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var translateTask: Task<Void, Never>?
    @ObservationIgnored private var appleJob: AppleJob?
    @ObservationIgnored private let lockScreen = LockScreenLyrics()
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var idleSince: Date?

    private struct AppleJob {
        let key: String
        let lines: [LyricLine]
        let target: String
        let source: DetectedLanguage
    }

    // MARK: - Lifecycle

    func becameActive() {
        isInBackground = false
        startTicking()
        startPolling()
    }

    func wentBackground() {
        isInBackground = true
        // While the Lock Screen card is moving, the silent audio keeps Subtext running, so keep going.
        guard !lockScreen.keepsAppAwake else { return }
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Spotify

    func connectSpotify(using session: WebAuthenticationSession) async {
        do {
            try await spotify.connect(using: session)
            spotifyMessage = nil
            followSpotify()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user closed the sign-in sheet.
        } catch {
            spotifyMessage = error.localizedDescription
        }
    }

    func disconnectSpotify() {
        spotify.disconnect()
        lockScreen.stop()
        pollTask?.cancel()
        pollTask = nil
        spotifyNow = nil
    }

    func followSpotify() {
        following = true
        isPlayingAlong = false
        if let now = spotifyNow {
            if record?.id != now.track.key { show(track: now.track, source: .spotify) }
            syncClock(to: now)
        }
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        guard spotify.isConnected else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.spotify.isConnected else { return }
                let delay = await self.pollOnce()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Asks Spotify what's playing; returns how long to wait before asking again.
    private func pollOnce() async -> Double {
        do {
            let token = try await spotify.validToken()
            let now = try await SpotifyAPI.currentlyPlaying(token: token)
            spotifyMessage = nil
            spotifyNow = now
            guard let now else {
                if following { clock.set(position: clock.position(), playing: false) }
                return 5
            }
            if following {
                if record?.id != now.track.key { show(track: now.track, source: .spotify) }
                syncClock(to: now)
            }
            // Ask again just after the song ends, so the next one shows up quickly.
            if now.isPlaying, let duration = now.track.duration {
                let remaining = duration - now.progress
                if remaining < 3 { return max(0.8, remaining + 0.6) }
            }
            return following ? (isInBackground ? 5 : 3) : 6
        } catch SpotifyError.unauthorized {
            spotify.invalidateAccessToken()
            return 1
        } catch SpotifyError.rateLimited(let wait) {
            return max(wait, 5)
        } catch SpotifyError.notConnected {
            return 30
        } catch {
            if (error as? URLError)?.code != .cancelled { spotifyMessage = error.localizedDescription }
            return 8
        }
    }

    private func syncClock(to now: SpotifyNowPlaying) {
        // Small differences are network jitter; ignoring them keeps the highlight steady.
        if clock.active, clock.playing == now.isPlaying, abs(clock.position(at: now.observedAt) - now.progress) < 0.4 {
            return
        }
        clock.set(position: now.progress, at: now.observedAt, playing: now.isPlaying)
        tick()
    }

    // MARK: - Choosing a song

    func pin(track: Track, source: SongSource, lyrics: Lyrics? = nil) {
        following = false
        isPlayingAlong = false
        show(track: track, source: source, preloaded: lyrics)
        selectedTab = .now
    }

    func pin(record: SongRecord) {
        pin(track: record.track, source: .history)
    }

    func pin(lrclib: LRCLibRecord) {
        pin(track: lrclib.track, source: .search, lyrics: lrclib.lyrics())
    }

    /// Called by the "Show Lyrics" shortcut action, usually right after Shazam.
    func openFromShortcut(title: String, artist: String) {
        let track = Track(title: title, artist: artist, primaryArtist: Track.primaryArtist(from: artist),
                          album: nil, duration: nil, artworkURL: nil, spotifyID: nil)
        selectedTab = .now
        if let now = spotifyNow, now.track.key == track.key {
            followSpotify()
        } else {
            pin(track: track, source: .shortcut)
        }
    }

    /// Lyrics the user pasted, for the song on screen or a new one.
    func useLyrics(text: String, title: String, artist: String) {
        let lyrics = LRCParser.lyrics(fromPasted: text)
        if var current = record, title.isEmpty {
            current.lyrics = lyrics
            current.lyricsChecked = Date()
            current.translation = nil
            record = current
            store.save(current)
            lyricsState = .loaded
            lyricsReady()
        } else {
            let track = Track(title: title.isEmpty ? "Untitled song" : title, artist: artist,
                              primaryArtist: Track.primaryArtist(from: artist),
                              album: nil, duration: nil, artworkURL: nil, spotifyID: nil)
            pin(track: track, source: .pasted, lyrics: lyrics)
        }
    }

    private func show(track: Track, source: SongSource, preloaded: Lyrics? = nil) {
        lyricsTask?.cancel()
        translateTask?.cancel()
        appleJob = nil
        clock = PlaybackClock()
        currentLine = nil
        translateState = .idle
        detected = nil
        localRoman = [:]
        self.source = source

        var current = store.get(track.key) ?? SongRecord(track: track, lyrics: nil, lyricsChecked: nil,
                                                         translation: nil, lastOpened: Date())
        // Spotify has the best details (artwork, length), so prefer them.
        if track.spotifyID != nil {
            current.track = track
        } else {
            current.track.album = current.track.album ?? track.album
            current.track.duration = current.track.duration ?? track.duration
        }
        current.lastOpened = Date()
        if let preloaded {
            current.lyrics = preloaded
            current.lyricsChecked = Date()
        }
        record = current
        store.save(current)

        if current.lyrics != nil {
            lyricsState = .loaded
            lyricsReady()
            return
        }
        if let checked = current.lyricsChecked, Date().timeIntervalSince(checked) < 6 * 3600 {
            lyricsState = .notFound
            return
        }
        fetchLyrics(for: current)
    }

    func retryLyrics() {
        guard let current = record else { return }
        fetchLyrics(for: current)
    }

    private func fetchLyrics(for current: SongRecord) {
        lyricsState = .loading
        let key = current.id
        let track = current.track
        lyricsTask = Task { [weak self] in
            do {
                let lyrics = try await LyricsService.lyrics(for: track)
                guard let self, !Task.isCancelled, self.record?.id == key else { return }
                self.updateRecord {
                    $0.lyrics = lyrics
                    $0.lyricsChecked = Date()
                }
                if lyrics == nil {
                    self.lyricsState = .notFound
                } else {
                    self.lyricsState = .loaded
                    self.lyricsReady()
                }
            } catch {
                guard let self, !Task.isCancelled, self.record?.id == key else { return }
                self.lyricsState = .failed(error.localizedDescription)
            }
        }
    }

    private func updateRecord(_ change: (inout SongRecord) -> Void) {
        guard var current = record else { return }
        change(&current)
        record = current
        store.save(current)
    }

    // MARK: - Translation

    private func lyricsReady() {
        guard let lyrics = record?.lyrics else { return }
        if lyrics.instrumental || lyrics.wordLines.isEmpty {
            translateState = .skipped("This one is instrumental.")
            return
        }
        let language = LanguageTools.detect(lyrics.wordLines)
        detected = language
        var roman: [Int: String] = [:]
        for line in lyrics.wordLines {
            if let r = LanguageTools.romanize(line.text, languageCode: language?.code) { roman[line.id] = r }
        }
        localRoman = roman
        tick()
        translateIfNeeded(force: false)
    }

    func translateIfNeeded(force: Bool) {
        guard let current = record, let lyrics = current.lyrics, !lyrics.instrumental else { return }
        let lines = lyrics.wordLines
        guard !lines.isEmpty else { return }
        let target = Prefs.targetLanguage

        if !force, let saved = current.translation, saved.targetLanguage == target, saved.complete {
            translateState = .done
            return
        }
        if !force, let language = detected, language.confidence > 0.8, LanguageTools.sameLanguage(language.code, target) {
            translateState = .skipped("This song is in \(language.name).")
            return
        }

        translateTask?.cancel()
        appleJob = nil
        let language = detected
        translateTask = Task { [weak self] in
            var appleOK = false
            if let language, language.appleCanTranslate, language.confidence >= 0.6 {
                appleOK = await LanguageTools.appleSupports(language.code, target: target)
            }
            guard let self, !Task.isCancelled, self.record?.id == current.id else { return }

            if let apiKey = Prefs.claudeKey, Prefs.engine == .claude || !appleOK {
                await self.runClaude(apiKey: apiKey, record: current, lines: lines, target: target)
            } else if appleOK, let language {
                self.startApple(record: current, lines: lines, target: target, source: language)
            } else if let language, !language.appleCanTranslate {
                self.translateState = .needsKey("This song is \(language.name) written in English letters, which Apple's translator can't read. Add a Claude API key in Settings to translate it.")
            } else if let language, language.confidence >= 0.6 {
                self.translateState = .needsKey("Apple's translator on this iPhone can't do \(language.name). Add a Claude API key in Settings to translate it.")
            } else {
                self.translateState = .needsKey("Couldn't tell which language this is. Add a Claude API key in Settings to translate it.")
            }
        }
    }

    private func runClaude(apiKey: String, record current: SongRecord, lines: [LyricLine], target: String) async {
        let model = Prefs.claudeModel
        var translation = SongTranslation(targetLanguage: target, engine: .claude, model: model.rawValue,
                                          sourceLanguageName: detected?.name, sourceLanguageCode: detected?.code)
        translateState = .working(done: 0, total: lines.count, engine: .claude)
        setTranslation(translation, for: current.id)

        let roman = localRoman
        let translator = ClaudeTranslator(apiKey: apiKey, model: model, targetName: TargetLanguage.name(for: target))
        do {
            for try await event in translator.stream(track: current.track, lines: lines) {
                switch event {
                case .language(let name, let code):
                    translation.sourceLanguageName = name
                    translation.sourceLanguageCode = code
                case .gloss(let id, var gloss):
                    if (gloss.romanization ?? "").isEmpty { gloss.romanization = roman[id] }
                    translation.glosses[id] = gloss
                case .about(let text):
                    translation.about = text
                }
                setTranslation(translation, for: current.id)
                if record?.id == current.id {
                    translateState = .working(done: translation.glosses.count, total: lines.count, engine: .claude)
                }
            }
            translation.complete = true
            setTranslation(translation, for: current.id, persist: true)
            if record?.id == current.id { translateState = .done }
        } catch {
            guard !Task.isCancelled else { return }
            setTranslation(translation, for: current.id, persist: true)
            if record?.id == current.id { translateState = .failed(error.localizedDescription) }
        }
    }

    private func startApple(record current: SongRecord, lines: [LyricLine], target: String, source: DetectedLanguage) {
        appleJob = AppleJob(key: current.id, lines: lines, target: target, source: source)
        translateState = .working(done: 0, total: lines.count, engine: .apple)
        let from = Locale.Language(identifier: source.code)
        let to = Locale.Language(identifier: target)
        if var config = appleConfig, config.source == from, config.target == to {
            config.invalidate()
            appleConfig = config
        } else {
            appleConfig = TranslationSession.Configuration(source: from, target: to)
        }
    }

    /// Runs inside `.translationTask` on the root view.
    func runAppleTranslation(_ session: TranslationSession) async {
        guard let job = appleJob else { return }
        appleJob = nil
        let requests = job.lines.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
        do {
            let responses = try await session.translations(from: requests)
            var translation = SongTranslation(targetLanguage: job.target, engine: .apple, model: nil,
                                              sourceLanguageName: job.source.name, sourceLanguageCode: job.source.code)
            let roman = record?.id == job.key ? localRoman : [:]
            for response in responses {
                guard let id = response.clientIdentifier.flatMap({ Int($0) }) else { continue }
                let unchanged = response.targetText.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(response.sourceText.trimmingCharacters(in: .whitespaces)) == .orderedSame
                translation.glosses[id] = LineGloss(translation: unchanged ? "" : response.targetText,
                                                    romanization: roman[id], note: nil)
            }
            translation.complete = true
            setTranslation(translation, for: job.key, persist: true)
            if record?.id == job.key { translateState = .done }
        } catch {
            if record?.id == job.key {
                translateState = .failed("Apple's translator couldn't do this song: \(error.localizedDescription)")
            }
        }
    }

    private func setTranslation(_ translation: SongTranslation, for key: String, persist: Bool = false) {
        if record?.id == key {
            record?.translation = translation
            if persist, let current = record { store.save(current) }
        } else if persist, var saved = store.get(key) {
            saved.translation = translation
            store.save(saved)
        }
    }

    func clearSavedTranslations() {
        store.clearTranslations()
        record?.translation = nil
        translateIfNeeded(force: false)
    }

    // MARK: - Line highlight

    func startPlayAlong(from line: LyricLine?) {
        guard let lyrics = record?.lyrics, lyrics.synced else { return }
        following = false
        let start = line?.time ?? lyrics.lines.first?.time ?? 0
        clock.set(position: max(0, start - Prefs.syncOffset + 0.05), playing: true)
        isPlayingAlong = true
        tick()
    }

    func pausePlayAlong() {
        clock.set(position: clock.position(), playing: false)
        isPlayingAlong = false
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func tick() {
        if clock.active, let lyrics = record?.lyrics, lyrics.synced, !lyrics.lines.isEmpty {
            let index = Self.lineIndex(at: clock.position() + Prefs.syncOffset, in: lyrics.lines)
            if index != currentLine { currentLine = index }
        } else if currentLine != nil {
            currentLine = nil
        }
        refreshLockScreen()
    }

    // MARK: - Lock Screen

    /// Builds the Lock Screen card from what's on screen. Called every tick; unchanged cards aren't re-sent.
    private func refreshLockScreen() {
        guard LockScreenLyrics.isEnabled, let record else {
            lockScreen.stop()
            return
        }
        let live = following && spotify.isConnected
        guard live || isPlayingAlong else {
            lockScreen.stop()
            return
        }
        let playing = live ? (spotifyNow?.isPlaying == true && spotifyNow?.track.key == record.id) : clock.playing

        // After two minutes without music, let iOS suspend Subtext to save battery.
        if playing {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = Date()
        }
        if let idleSince, Date().timeIntervalSince(idleSince) > 120 {
            lockScreen.stop()
            return
        }

        var state = LockScreenLyrics.State(title: record.track.title, artist: record.track.artist, line: "♪",
                                           romanization: nil, translation: nil, songStart: nil, songEnd: nil,
                                           isPlaying: playing, status: nil)
        if playing, let start = clock.songStart, let duration = record.track.duration {
            state.songStart = start
            state.songEnd = start.addingTimeInterval(duration)
        }
        switch lyricsState {
        case .loading: state.status = "Finding lyrics…"
        case .notFound, .failed: state.status = "No lyrics found for this song."
        case .idle, .loaded: break
        }
        if state.status == nil, let lyrics = record.lyrics {
            if lyrics.instrumental {
                state.status = "Instrumental"
            } else if !lyrics.synced {
                state.status = "These lyrics aren't timed. Open Subtext to read them."
            } else if let id = currentLine, let line = lyrics.lines.first(where: { $0.id == id }), !line.isBreak {
                let defaults = UserDefaults.standard
                let gloss = record.translation?.glosses[id]
                state.line = line.text
                if defaults.object(forKey: Prefs.Key.showRomanization) as? Bool ?? true {
                    state.romanization = gloss?.romanization ?? localRoman[id]
                }
                if defaults.object(forKey: Prefs.Key.showTranslation) as? Bool ?? true {
                    state.translation = gloss?.translation
                }
            }
        }
        lockScreen.show(state, keepAwake: true)
    }

    #if DEBUG
    /// Lets the simulator be driven without taps:
    /// SIMCTL_CHILD_SUBTEXT_DEMO_QUERY="song artist" [SUBTEXT_DEMO_LINE=12] [SUBTEXT_DEMO_TAB=settings].
    func runDebugLaunchHooks() async {
        let env = ProcessInfo.processInfo.environment
        if let query = env["SUBTEXT_DEMO_QUERY"],
           let results = try? await LyricsService.search(query: query),
           let first = results.first(where: \.hasSynced) ?? results.first(where: \.hasAny) {
            pin(lrclib: first)
            if let lineText = env["SUBTEXT_DEMO_LINE"], let index = Int(lineText),
               let line = record?.lyrics?.lines.first(where: { $0.id >= index && !$0.isBreak }) {
                startPlayAlong(from: line)
            }
        }
        switch env["SUBTEXT_DEMO_TAB"] {
        case "settings": selectedTab = .settings
        case "history": selectedTab = .history
        default: break
        }
    }
    #endif

    /// The last line that has started by `time`.
    static func lineIndex(at time: TimeInterval, in lines: [LyricLine]) -> Int? {
        var low = 0, high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if (lines[mid].time ?? 0) <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found.map { lines[$0].id }
    }
}
