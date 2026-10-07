import AVFoundation

/// Plays silence mixed under Spotify so iOS keeps Subtext running while the phone is locked,
/// which lets it move the Lock Screen lyrics along. Mixing means Spotify is never interrupted.
@MainActor
final class BackgroundAudioKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silence: AVAudioPCMBuffer
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        silence.frameLength = silence.frameCapacity
        if let channels = silence.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(silence.frameLength))
            }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let center = NotificationCenter.default
        // A phone call or Siri stops our audio; start again when it's over.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated { self?.restart() }
        })
        // Plugging in or removing earphones reconfigures the engine.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
    }

    private func restart() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        start()
    }
}
