import AVFoundation

/// Plays silence mixed under Spotify so iOS keeps Subtext running while the phone is locked,
/// which lets it move the Lock Screen lyrics along. Mixing means Spotify is never interrupted.
@MainActor
final class BackgroundAudioKeeper {
    private var player: AVAudioPlayer?
    private var wanted = false
    private var lastFailureLogged = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    /// True only while the silence is really playing.
    var isRunning: Bool { wanted && player?.isPlaying == true }

    init() {
        let center = NotificationCenter.default
        // A call or Siri stops our audio; play again when it's over.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                ActivityLog.add(began ? "Background audio interrupted" : "Background audio interruption ended")
                if !began { self.ensurePlaying() }
            }
        })
        // Earphones in or out, or another app changing the audio route.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensurePlaying() }
        })
        // iOS restarted its audio system; the old player is gone.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ActivityLog.add("iOS reset its audio system")
                self.player = nil
                self.ensurePlaying()
            }
        })
    }

    func start() {
        wanted = true
        ensurePlaying()
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        player?.stop()
        ActivityLog.add("Background audio stopped")
    }

    /// Starts the silence again if it should be playing but isn't. Called on every tick too, so it also
    /// recovers when something stopped the audio without telling us.
    func ensurePlaying() {
        guard wanted, player?.isPlaying != true else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let silence = try AVAudioPlayer(data: Self.silence)
                silence.numberOfLoops = -1
                silence.prepareToPlay()
                player = silence
            }
            if player?.play() == true {
                ActivityLog.add("Background audio playing")
            } else {
                logFailure("Background audio didn't start")
            }
        } catch {
            logFailure("Background audio failed: \(error.localizedDescription)")
        }
    }

    private func logFailure(_ message: String) {
        guard Date().timeIntervalSince(lastFailureLogged) > 10 else { return }
        lastFailureLogged = Date()
        ActivityLog.add(message)
    }

    /// One second of silence as a WAV file: 8 kHz, 16-bit, mono.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8_000
        let byteCount = sampleRate * 2
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + byteCount); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1); append32(sampleRate); append32(sampleRate * 2)
        append16(2); append16(16)
        append("data"); append32(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }()
}
