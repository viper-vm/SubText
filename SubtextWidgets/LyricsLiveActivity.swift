import ActivityKit
import SwiftUI
import WidgetKit

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyricsView(state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    LyricLines(state: context.state, isStale: context.isStale, compact: true)
                }
            } compactLeading: {
                Image(systemName: "music.note").foregroundStyle(Color("AccentColor"))
            } compactTrailing: {
                Text(context.state.translation ?? context.state.line)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(Color("AccentColor"))
            }
        }
    }
}

private struct LockScreenLyricsView: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color("AccentColor"))
                Text(state.title).font(.caption.weight(.semibold)).lineLimit(1)
                if !state.artist.isEmpty {
                    Text(state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !state.isPlaying && !isStale {
                    Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            LyricLines(state: state, isStale: isStale, compact: false)
            if state.isPlaying, !isStale, let start = state.songStart, let end = state.songEnd, end > start {
                ProgressView(timerInterval: start...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(Color("AccentColor"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct LyricLines: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isStale {
                Text("Open Subtext to keep the lyrics moving.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let status = state.status {
                Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(state.line)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(2)
                if let romanization = state.romanization, !romanization.isEmpty {
                    Text(romanization).font(.caption).italic().foregroundStyle(.secondary).lineLimit(1)
                }
                if let translation = state.translation, !translation.isEmpty {
                    Text(translation)
                        .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                        .foregroundStyle(Color("AccentColor"))
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
