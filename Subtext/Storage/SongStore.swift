import CryptoKit
import Foundation
import Observation

/// Every song the user has opened, with its lyrics and translation, saved as one JSON file per song.
@MainActor
@Observable
final class SongStore {
    private(set) var records: [String: SongRecord] = [:]
    @ObservationIgnored private let directory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let record = try? decoder.decode(SongRecord.self, from: data) {
                records[record.id] = record
            }
        }
    }

    var history: [SongRecord] { records.values.sorted { $0.lastOpened > $1.lastOpened } }

    func get(_ key: String) -> SongRecord? { records[key] }

    func save(_ record: SongRecord) {
        records[record.id] = record
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: file(for: record.id), options: .atomic)
        }
    }

    func delete(_ key: String) {
        records[key] = nil
        try? FileManager.default.removeItem(at: file(for: key))
    }

    /// Removes saved translations and answers; lyrics and history stay.
    func clearTranslations() {
        for var record in records.values where record.translation != nil || record.questions != nil {
            record.translation = nil
            record.questions = nil
            save(record)
        }
    }

    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + ".json")
    }
}
