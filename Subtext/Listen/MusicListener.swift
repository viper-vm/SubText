import AVFAudio
import ShazamKit

enum ListenError: LocalizedError {
    case microphoneDenied
    case shazamNotEnabled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Subtext can't use the microphone. Allow it in the iPhone's Settings app → Subtext → Microphone."
        case .shazamNotEnabled:
            "Listening uses Apple's song recognition (ShazamKit), which needs the paid Apple Developer Program. The README explains how to switch it on."
        case .failed(let message):
            "Couldn't recognize the music: \(message)"
        }
    }
}

/// Listens through the microphone and recognizes songs playing nearby with Apple's ShazamKit.
@MainActor
final class MusicListener {
    struct Heard {
        let track: Track
        /// Where in the song the music is right now, in seconds.
        let offset: TimeInterval
        let date: Date
    }

    private var session: SHManagedSession?
    private var task: Task<Void, Never>?

    func start(onHeard: @escaping (Heard) -> Void, onNothing: @escaping () -> Void,
               onError: @escaping (Error) -> Void) async throws {
        guard session == nil else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw ListenError.microphoneDenied }
        let session = SHManagedSession()
        self.session = session
        await session.prepare()
        task = Task {
            // Keeps matching while the session runs: every result says what's playing and where.
            for await result in session.results {
                switch result {
                case .match(let match):
                    if let item = match.mediaItems.first { onHeard(Self.heard(item)) }
                case .noMatch:
                    onNothing()
                case .error(let error, _):
                    onError(Self.explain(error))
                @unknown default:
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.cancel()
        session = nil
    }

    private static func heard(_ item: SHMatchedMediaItem) -> Heard {
        let artist = item.artist ?? ""
        let track = Track(title: item.title ?? "Unknown song", artist: artist, primaryArtist: Track.primaryArtist(from: artist),
                          album: nil, duration: nil, artworkURL: item.artworkURL, spotifyID: nil)
        return Heard(track: track, offset: item.predictedCurrentMatchOffset, date: Date())
    }

    /// ShazamKit answers "match attempt failed" (202) when its service isn't switched on for the app.
    private static func explain(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == SHErrorDomain, nsError.code == 202 {
            let details = (nsError.userInfo.values.map { "\($0)" } + [nsError.localizedDescription]).joined(separator: " ")
            if details.localizedCaseInsensitiveContains("app service") || details.localizedCaseInsensitiveContains("not enabled") {
                return ListenError.shazamNotEnabled
            }
        }
        return ListenError.failed(nsError.localizedDescription)
    }
}
