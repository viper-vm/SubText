import Foundation

/// Reads LRC ("[01:02.50] words") and plain lyrics into lines.
enum LRCParser {
    private static let tag = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    static func looksTimed(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let ns = line.trimmingCharacters(in: .whitespaces) as NSString
            return tag.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) != nil
        }
    }

    static func parse(synced text: String) -> [LyricLine] {
        var entries: [(time: TimeInterval, text: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = raw.trimmingCharacters(in: .whitespaces)
            var times: [TimeInterval] = []
            // A line can carry several leading tags: "[00:12.00][01:30.00] chorus".
            while true {
                let ns = rest as NSString
                guard let m = tag.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) else { break }
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: m.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                rest = ns.substring(from: m.range.location + m.range.length)
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((time, words)) }
        }
        entries.sort { $0.time < $1.time }
        // Drop a leading break and collapse runs of breaks.
        var lines: [LyricLine] = []
        for entry in entries {
            let isBreak = entry.text.isEmpty
            if isBreak && (lines.isEmpty || lines.last!.isBreak) { continue }
            lines.append(LyricLine(id: lines.count, time: entry.time, text: entry.text))
        }
        return lines
    }

    static func parse(plain text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let words = raw.trimmingCharacters(in: .whitespaces)
            if words.isEmpty && (lines.isEmpty || lines.last!.isBreak) { continue }
            lines.append(LyricLine(id: lines.count, time: nil, text: words))
        }
        while lines.last?.isBreak == true { lines.removeLast() }
        return lines
    }

    /// Picks the right parser for text the user pasted.
    static func lyrics(fromPasted text: String) -> Lyrics {
        if looksTimed(text) {
            let lines = parse(synced: text)
            if !lines.isEmpty { return Lyrics(lines: lines, synced: true) }
        }
        return Lyrics(lines: parse(plain: text), synced: false)
    }
}
