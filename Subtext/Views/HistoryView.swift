import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            let history = model.store.history
            List {
                ForEach(history) { record in
                    Button { model.pin(record: record) } label: { HistoryRow(record: record) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets { model.store.delete(history[index].id) }
                }
            }
            .overlay {
                if history.isEmpty {
                    ContentUnavailableView("No songs yet", systemImage: "clock",
                                           description: Text("Songs you read along with are saved here, translations included."))
                }
            }
            .navigationTitle("History")
        }
    }
}

private struct HistoryRow: View {
    let record: SongRecord

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: record.track.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.track.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(record.track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let language = record.translation?.sourceLanguageName {
                        Text(language)
                    } else if record.lyrics == nil {
                        Text("No lyrics")
                    }
                    Text(record.lastOpened, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
