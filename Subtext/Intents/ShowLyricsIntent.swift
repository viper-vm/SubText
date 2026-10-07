import AppIntents

/// A Shortcuts action. Paired with Apple's "Shazam It" action it hands any song playing nearby to Subtext.
struct ShowLyricsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Lyrics"
    static let description = IntentDescription("Opens Subtext on a song so you can read its lyrics and translation.")
    static let openAppWhenRun = true

    @Parameter(title: "Song")
    var song: String

    @Parameter(title: "Artist")
    var artist: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Show lyrics for \(\.$song) by \(\.$artist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.openFromShortcut(title: song, artist: artist ?? "")
        return .result()
    }
}
