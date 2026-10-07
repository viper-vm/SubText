import Foundation

/// What Spotify is playing, and where in the song it was when we asked.
struct SpotifyNowPlaying: Equatable {
    var track: Track
    /// Seconds into the song at `observedAt`.
    var progress: TimeInterval
    var isPlaying: Bool
    var observedAt: Date
}

enum SpotifyAPI {
    private struct CurrentlyPlaying: Decodable {
        let progress_ms: Int?
        let is_playing: Bool
        let currently_playing_type: String?
        let item: Item?

        struct Item: Decodable {
            let id: String?
            let name: String
            let duration_ms: Int
            let artists: [Artist]?
            let album: Album?
        }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable {
            let name: String?
            let images: [Image]?
        }
        struct Image: Decodable {
            let url: String
            let width: Int?
        }
    }

    /// nil when nothing (or a podcast or ad) is playing.
    static func currentlyPlaying(token: String) async throws -> SpotifyNowPlaying? {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=track")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let roundTrip = Date().timeIntervalSince(started)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        switch status {
        case 204:
            return nil
        case 200:
            break
        case 401:
            throw SpotifyError.unauthorized
        case 429:
            let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 10
            throw SpotifyError.rateLimited(wait)
        default:
            throw SpotifyError.http(status, SpotifyError.message(from: data))
        }
        guard !data.isEmpty else { return nil }

        let playing = try JSONDecoder().decode(CurrentlyPlaying.self, from: data)
        guard let item = playing.item, (playing.currently_playing_type ?? "track") == "track" else { return nil }

        let artists = (item.artists ?? []).map(\.name)
        let images = (item.album?.images ?? []).sorted { ($0.width ?? 0) > ($1.width ?? 0) }
        let artwork = (images.first { ($0.width ?? 0) <= 320 } ?? images.first)?.url
        let track = Track(
            title: item.name,
            artist: artists.joined(separator: ", "),
            primaryArtist: artists.first ?? "",
            album: item.album?.name,
            duration: Double(item.duration_ms) / 1000,
            artworkURL: artwork.flatMap(URL.init(string:)),
            spotifyID: item.id
        )
        // The position is from roughly the middle of the request.
        return SpotifyNowPlaying(track: track, progress: Double(playing.progress_ms ?? 0) / 1000,
                                 isPlaying: playing.is_playing, observedAt: started.addingTimeInterval(roundTrip / 2))
    }
}
