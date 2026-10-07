import ActivityKit
import Foundation

/// The Lock Screen card. Shared by the app (which starts and updates it) and the widget extension (which draws it).
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        /// The line being sung, or "♪" between lines.
        var line: String
        var romanization: String?
        var translation: String?
        /// When the song started and will end, so the progress bar can move without updates.
        var songStart: Date?
        var songEnd: Date?
        var isPlaying: Bool
        /// Shown instead of a line, e.g. "No lyrics found for this song."
        var status: String?
    }
}
