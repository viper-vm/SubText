import Foundation

/// A short log of what Subtext did in the background (Lock Screen card, background audio, song changes,
/// listening), shown in Settings so a problem can be traced afterwards.
@MainActor
enum ActivityLog {
    private static let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("background-log.txt")
    }()
    private static var lines: [String] = {
        guard let saved = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return saved.split(separator: "\n").map(String.init)
    }()
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter
    }()

    static func add(_ message: String) {
        lines.append("\(time.string(from: Date()))  \(message)")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Newest first.
    static var text: String { lines.reversed().joined(separator: "\n") }

    static func clear() {
        lines = []
        try? FileManager.default.removeItem(at: file)
    }
}
