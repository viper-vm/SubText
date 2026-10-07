import ActivityKit
import Foundation

/// Owns the Lock Screen card and the background audio that keeps it moving.
@MainActor
final class LockScreenLyrics {
    typealias State = LyricsActivityAttributes.ContentState

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: State?
    /// The song whose card the user swiped away; don't bring it back for that song.
    private var dismissedTitle: String?
    private let audio = BackgroundAudioKeeper()

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: Prefs.Key.lockScreen) as? Bool ?? true }
    static var systemAllows: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var keepsAppAwake: Bool { audio.isRunning }

    init() {
        // Cards left over from an earlier run can't be updated any more.
        for old in Activity<LyricsActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func show(_ state: State, keepAwake: Bool) {
        guard Self.isEnabled, Self.systemAllows else {
            stop()
            return
        }
        if keepAwake { audio.start() } else { audio.stop() }

        if let current = activity, current.activityState == .dismissed || current.activityState == .ended {
            if current.activityState == .dismissed { dismissedTitle = lastState?.title }
            activity = nil
            lastState = nil
        }
        if dismissedTitle != nil, dismissedTitle == state.title { return }
        dismissedTitle = nil
        guard state != lastState else { return }

        // Past the stale date the card asks to open Subtext, in case iOS stopped the app.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(state.isPlaying ? 120 : 900))
        if let activity {
            lastState = state
            Task { await activity.update(content) }
        } else if let started = try? Activity.request(attributes: LyricsActivityAttributes(), content: content, pushType: nil) {
            // Only possible while Subtext is on screen; otherwise this waits until it next opens.
            activity = started
            lastState = state
        }
    }

    func stop() {
        audio.stop()
        lastState = nil
        if let activity {
            self.activity = nil
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
