import Foundation

enum Config {
    /// The Client ID from developer.spotify.com/dashboard, set in Config/Local.xcconfig (see the README).
    /// It is not a secret: Subtext signs in with PKCE, so there is no client secret. It can also be pasted in Settings.
    static let spotifyClientID: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }()
    static let spotifyRedirectURI = "subtext://callback"
}

enum ClaudeModel: String, CaseIterable, Identifiable, Codable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-4-5"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 4.5"
        }
    }
    var detail: String {
        switch self {
        case .opus: "Best translations and notes. About 5–10¢ per new song."
        case .sonnet: "Very good and quicker. About 3–5¢ per new song."
        case .haiku: "Fastest and cheapest. About 1–3¢ per new song."
        }
    }
}

struct TargetLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [TargetLanguage] = [
        .init(code: "en", name: "English"), .init(code: "hi", name: "Hindi"), .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"), .init(code: "de", name: "German"), .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"), .init(code: "ja", name: "Japanese"), .init(code: "ko", name: "Korean"),
        .init(code: "zh-Hans", name: "Chinese (Simplified)"), .init(code: "ar", name: "Arabic"),
        .init(code: "ru", name: "Russian"), .init(code: "tr", name: "Turkish"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? LanguageTools.displayName(code)
    }
}

/// User settings. Views bind to the same keys with @AppStorage.
enum Prefs {
    enum Key {
        static let clientID = "spotifyClientID"
        static let engine = "translationEngine"
        static let model = "claudeModel"
        static let target = "targetLanguage"
        static let showRomanization = "showRomanization"
        static let showTranslation = "showTranslation"
        static let showNotes = "showNotes"
        static let offset = "syncOffset"
        static let lockScreen = "lockScreenLyrics"
    }
    static let claudeKeyAccount = "anthropic.apiKey"

    private static var defaults: UserDefaults { .standard }

    static var spotifyClientID: String {
        let saved = defaults.string(forKey: Key.clientID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? Config.spotifyClientID : saved
    }
    static var engine: TranslationEngine {
        TranslationEngine(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? .apple
    }
    static var claudeModel: ClaudeModel {
        ClaudeModel(rawValue: defaults.string(forKey: Key.model) ?? "") ?? .opus
    }
    static var targetLanguage: String { defaults.string(forKey: Key.target) ?? "en" }
    static var syncOffset: Double { defaults.double(forKey: Key.offset) }

    static var claudeKey: String? {
        #if DEBUG
        if let testKey = ProcessInfo.processInfo.environment["SUBTEXT_CLAUDE_KEY"] { return testKey }
        #endif
        guard let key = Keychain.get(claudeKeyAccount), !key.isEmpty else { return nil }
        return key
    }
    /// "…a1b2" so Settings can show that a key is saved without showing it.
    static var claudeKeyHint: String? { claudeKey.map { "…" + $0.suffix(4) } }
}
