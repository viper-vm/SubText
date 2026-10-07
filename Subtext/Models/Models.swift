import Foundation

/// Where the song on screen came from.
enum SongSource: String, Codable {
    case spotify, search, shortcut, history, pasted
}

struct Track: Codable, Hashable {
    var title: String
    /// Every artist, joined with ", ".
    var artist: String
    /// The first artist; lyric databases usually list only this one.
    var primaryArtist: String
    var album: String?
    /// Seconds.
    var duration: TimeInterval?
    var artworkURL: URL?
    var spotifyID: String?

    var key: String { SongKey.make(title: title, artist: primaryArtist) }

    /// Splits "A feat. B", "A & B" or "A, B" down to "A".
    static func primaryArtist(from artist: String) -> String {
        var first = artist
        for separator in [",", "&", " feat.", " feat ", " ft.", " featuring ", " x ", " X ", " with "] {
            if let range = first.range(of: separator, options: .caseInsensitive) {
                first = String(first[..<range.lowerBound])
            }
        }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? artist : trimmed
    }
}

/// One key per song, so a song found on Spotify, by search or by Shazam shares its saved translation.
enum SongKey {
    static func make(title: String, artist: String) -> String {
        let raw = "\(artist)|\(TitleCleaner.clean(title))".lowercased()
        return raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

enum TitleCleaner {
    private static let patterns = [
        // "(feat. X)", "[Live]", "(From "Film")", "(Remastered 2011)", "(Lofi Flip)"…
        #"\s*[\(\[][^\)\]]*\b(feat\.?|ft\.|featuring|with|from|remaster(ed)?|live|version|edit|mix|remix|acoustic|unplugged|lo-?fi|slowed|reverb|sped up|bonus|explicit|radio|mono|stereo|soundtrack)\b[^\)\]]*[\)\]]"#,
        // " - Remastered 2011", " - From "Film"", " - Live at…"
        #"\s+[-–—]\s+.*\b(remaster(ed)?|live|version|edit|mix|remix|acoustic|unplugged|from|feat\.?|radio|mono|stereo|soundtrack)\b.*$"#,
    ]

    static func clean(_ title: String) -> String {
        var cleaned = title
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? title : cleaned
    }
}

struct LyricLine: Codable, Hashable, Identifiable {
    var id: Int
    /// Seconds from the start of the song; nil for untimed lyrics.
    var time: TimeInterval?
    var text: String

    /// An empty line marks a break (an instrumental gap in timed lyrics).
    var isBreak: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct Lyrics: Codable, Hashable {
    var lines: [LyricLine]
    var synced: Bool
    var lrclibID: Int?
    var instrumental: Bool = false

    var wordLines: [LyricLine] { lines.filter { !$0.isBreak } }
}

/// What the app shows under one lyric line.
struct LineGloss: Codable, Hashable {
    var translation: String
    var romanization: String?
    var note: String?
}

enum TranslationEngine: String, Codable, CaseIterable, Identifiable {
    case claude, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: "Claude"
        case .apple: "Apple, on this iPhone (free)"
        }
    }
}

struct SongTranslation: Codable, Hashable {
    var targetLanguage: String
    var engine: TranslationEngine
    var model: String?
    var sourceLanguageName: String?
    var sourceLanguageCode: String?
    var glosses: [Int: LineGloss] = [:]
    var about: String?
    var complete = false
}

struct SongRecord: Codable, Identifiable, Hashable {
    var id: String { track.key }
    var track: Track
    var lyrics: Lyrics?
    /// When we last asked LRCLIB; lets us avoid asking again for songs it doesn't have.
    var lyricsChecked: Date?
    var translation: SongTranslation?
    var lastOpened: Date
}
