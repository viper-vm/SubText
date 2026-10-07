import Foundation
import NaturalLanguage
import Translation

struct DetectedLanguage: Equatable {
    let code: String
    let name: String
    /// How sure the detector is (0–1).
    let confidence: Double
    /// false for text Apple's translator can't read, such as Hindi or Punjabi typed in English letters.
    var appleCanTranslate = true
}

enum LanguageTools {
    static func detect(_ lines: [LyricLine]) -> DetectedLanguage? {
        let text = lines.map(\.text).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Apple's detector reads romanized Hindi and Punjabi as Indonesian or Dutch, so check for it first.
        if !hasNonLatinLetters(text), looksLikeRomanizedSouthAsian(text) {
            return DetectedLanguage(code: "hi-Latn", name: "Hindi or Punjabi", confidence: 0.9, appleCanTranslate: false)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined else { return nil }
        return DetectedLanguage(code: language.rawValue, name: displayName(language.rawValue), confidence: confidence)
    }

    /// Words that are common in Hindi, Urdu and Punjabi lyrics written in English letters and rare in other languages.
    private static let southAsianWords: Set<String> = [
        "hai", "hain", "tum", "tera", "teri", "tere", "mera", "meri", "mere", "dil", "nahi", "nahin", "hoon", "kya",
        "kyun", "yeh", "pyaar", "pyar", "ishq", "yaar", "sajna", "jaana", "tainu", "mainu", "menu", "tenu", "kithe",
        "sohneya", "sohni", "mundeya", "kudi", "assi", "tusi", "rabba", "mahi", "zindagi", "aankhon", "sapne", "kaise",
        "kahan", "mujhe", "tujhe", "hum", "tumhe", "tumko", "karda", "karde", "gaya", "gayi", "raha", "rahi", "wala",
        "haye", "jind", "akhiyan", "ankhiyan", "saath", "baatein", "chalein", "dekho", "kuch", "bina", "humko",
    ]

    static func looksLikeRomanizedSouthAsian(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard words.count >= 6 else { return false }
        let hits = words.filter { southAsianWords.contains($0) }.count
        return hits >= 3 && Double(hits) / Double(words.count) >= 0.08
    }

    static func displayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    static func baseCode(_ code: String) -> String {
        Locale.Language(identifier: code).languageCode?.identifier ?? code
    }

    static func sameLanguage(_ a: String, _ b: String) -> Bool { baseCode(a) == baseCode(b) }

    /// Whether Apple's on-device translator can do this language pair (it may still need a download).
    static func appleSupports(_ source: String, target: String) async -> Bool {
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                         to: Locale.Language(identifier: target))
        return status == .installed || status == .supported
    }

    // MARK: - Romanization (on-device fallback when Claude isn't used)

    static func hasNonLatinLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.properties.isAlphabetic else { return false }
            let v = scalar.value
            let latin = v < 0x0250 || (0x1E00...0x1EFF).contains(v) || (0x2C60...0x2C7F).contains(v)
                || (0xA720...0xA7FF).contains(v) || (0xFF21...0xFF5A).contains(v)
            return !latin
        }
    }

    static func romanize(_ text: String, languageCode: String?) -> String? {
        guard hasNonLatinLetters(text) else { return nil }
        let base = languageCode.map(baseCode)
        var result = base == "ja" ? japaneseRomaji(text) : nil
        if result == nil { result = text.applyingTransform(.toLatin, reverse: false) }
        guard var latin = result else { return nil }
        // Keep tone marks for Chinese and Vietnamese; elsewhere plain letters read more easily.
        if base != "zh" && base != "vi" {
            latin = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        }
        latin = latin.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return latin.isEmpty || latin == text ? nil : latin
    }

    /// Japanese needs word-level readings; the general transform reads kanji as Chinese.
    private static func japaneseRomaji(_ text: String) -> String? {
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        guard let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, string, range,
                                                      kCFStringTokenizerUnitWordBoundary,
                                                      Locale(identifier: "ja") as CFLocale) else { return nil }
        var parts: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (text as NSString).substring(with: NSRange(location: tokenRange.location, length: tokenRange.length))
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
               !reading.isEmpty {
                parts.append(reading)
            } else {
                parts.append(token)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
