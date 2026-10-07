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
    /// The song we last failed to start a card for, so the log isn't flooded.
    private var failedTitle: String?
    /// Updates run one after another, so an older one can never land after a newer one.
    private var updateTask: Task<Void, Never>?
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
            stop(reason: Self.isEnabled ? "Live Activities are turned off for Subtext in iOS Settings" : "turned off in Settings")
            return
        }
        if keepAwake { audio.start() } else { audio.stop() }

        if let current = activity, current.activityState == .dismissed || current.activityState == .ended {
            if current.activityState == .dismissed {
                dismissedTitle = lastState?.title
                ActivityLog.add("Lock Screen card was swiped away")
            } else {
                ActivityLog.add("Lock Screen card was ended by iOS")
            }
            activity = nil
            lastState = nil
        }
        if dismissedTitle != nil, dismissedTitle == state.title { return }
        dismissedTitle = nil
        guard state != lastState else { return }

        // Past the stale date the card asks to open Subtext, in case iOS stopped the app.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(state.isPlaying ? 120 : 900))
        if let activity {
            if lastState?.title != state.title { ActivityLog.add("Lock Screen card now shows \(state.title)") }
            lastState = state
            let previous = updateTask
            updateTask = Task {
                await previous?.value
                await activity.update(content)
            }
        } else {
            do {
                // Only possible while Subtext is on screen; otherwise this waits until it next opens.
                activity = try Activity.request(attributes: LyricsActivityAttributes(), content: content, pushType: nil)
                lastState = state
                failedTitle = nil
                ActivityLog.add("Lock Screen card started for \(state.title)")
            } catch {
                if failedTitle != state.title {
                    failedTitle = state.title
                    ActivityLog.add("Couldn't start the Lock Screen card: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop(reason: String) {
        audio.stop()
        lastState = nil
        if let activity {
            self.activity = nil
            ActivityLog.add("Lock Screen card ended: \(reason)")
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
