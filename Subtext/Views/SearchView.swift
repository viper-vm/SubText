import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LRCLibRecord] = []
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(results) { result in
                    Button {
                        model.pin(lrclib: result)
                        dismiss()
                    } label: {
                        ResultRow(result: result)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if searching && results.isEmpty {
                    ProgressView()
                } else if results.isEmpty && message == nil {
                    ContentUnavailableView(
                        query.count < 2 ? "Find a song" : "No lyrics found",
                        systemImage: "magnifyingglass",
                        description: Text(query.count < 2 ? "Type the song title, and the artist if you know it."
                                                          : "Try fewer words or a different spelling.")
                    )
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Song and artist")
            .autocorrectionDisabled()
            .task(id: query) { await runSearch() }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            results = []
            message = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await LyricsService.search(query: text)
            guard !Task.isCancelled else { return }
            results = found.filter(\.hasAny)
            message = nil
        } catch {
            guard !Task.isCancelled else { return }
            message = error.localizedDescription
        }
    }
}

private struct ResultRow: View {
    let result: LRCLibRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.trackName ?? "Unknown song").font(.body.weight(.semibold))
            Text([result.artistName, result.albumName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let duration = result.duration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if result.instrumental == true {
                    Chip(text: "Instrumental")
                } else if result.hasSynced {
                    Chip(text: "Timed", systemImage: "clock", tint: .accentColor)
                } else {
                    Chip(text: "Not timed")
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
