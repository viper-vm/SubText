import Foundation

/// A song as LRCLIB (lrclib.net, free and open) returns it.
struct LRCLibRecord: Decodable, Identifiable, Hashable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
    var hasAny: Bool { hasSynced || !(plainLyrics ?? "").isEmpty || instrumental == true }

    func lyrics() -> Lyrics? {
        if instrumental == true { return Lyrics(lines: [], synced: false, lrclibID: id, instrumental: true, duration: duration) }
        if let synced = syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced: synced)
            if !lines.isEmpty { return Lyrics(lines: lines, synced: true, lrclibID: id, duration: duration) }
        }
        if let plain = plainLyrics, !plain.isEmpty {
            return Lyrics(lines: LRCParser.parse(plain: plain), synced: false, lrclibID: id, duration: duration)
        }
        return nil
    }

    var track: Track {
        let artist = artistName ?? ""
        return Track(title: trackName ?? "Unknown song", artist: artist, primaryArtist: Track.primaryArtist(from: artist),
                     album: albumName, duration: duration, artworkURL: nil, spotifyID: nil)
    }
}

enum LyricsError: LocalizedError {
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .http(let code): "The lyrics service answered with error \(code). Try again in a moment."
        }
    }
}

enum LyricsService {
    private static let base = "https://lrclib.net/api"
    private static let userAgent = "Subtext/0.1 (personal iOS app)"

    /// Finds the best lyrics for a track: exact match first, then looser searches.
    static func lyrics(for track: Track) async throws -> Lyrics? {
        let cleaned = TitleCleaner.clean(track.title)
        let artist = track.primaryArtist

        if let album = track.album, let duration = track.duration {
            for title in [track.title, cleaned].uniqued() {
                if let record = try await get(title: title, artist: artist, album: album, duration: duration),
                   let lyrics = record.lyrics() {
                    return lyrics
                }
            }
        }

        var candidates = try await search(["track_name": cleaned, "artist_name": artist])
        if candidates.filter(\.hasAny).isEmpty {
            candidates = try await search(["q": "\(cleaned) \(artist)"])
        }
        if candidates.filter(\.hasAny).isEmpty, track.artist != artist {
            candidates = try await search(["track_name": cleaned, "artist_name": track.artist])
        }
        return best(of: candidates, duration: track.duration)?.lyrics()
    }

    /// Free-text search for the search screen.
    static func search(query: String) async throws -> [LRCLibRecord] {
        try await search(["q": query])
    }

    private static func get(title: String, artist: String, album: String, duration: Double) async throws -> LRCLibRecord? {
        let (data, code) = try await request("/get", [
            "track_name": title, "artist_name": artist, "album_name": album, "duration": String(Int(duration.rounded())),
        ])
        if code == 404 { return nil }
        guard code == 200 else { throw LyricsError.http(code) }
        return try? JSONDecoder().decode(LRCLibRecord.self, from: data)
    }

    private static func search(_ params: [String: String]) async throws -> [LRCLibRecord] {
        let (data, code) = try await request("/search", params)
        guard code == 200 else { throw LyricsError.http(code) }
        return (try? JSONDecoder().decode([LRCLibRecord].self, from: data)) ?? []
    }

    /// Prefers timed lyrics whose length matches the song; otherwise any lyrics.
    private static func best(of candidates: [LRCLibRecord], duration: Double?) -> LRCLibRecord? {
        let usable = candidates.filter(\.hasAny)
        guard let duration else { return usable.first(where: \.hasSynced) ?? usable.first }
        func distance(_ r: LRCLibRecord) -> Double { abs((r.duration ?? 0) - duration) }
        let close = usable.filter { distance($0) <= 4 }.sorted { distance($0) < distance($1) }
        return close.first(where: \.hasSynced) ?? close.first ?? usable.first(where: \.hasSynced) ?? usable.first
    }

    private static func request(_ path: String, _ params: [String: String]) async throws -> (Data, Int) {
        var components = URLComponents(string: base + path)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
