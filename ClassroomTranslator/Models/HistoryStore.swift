import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class HistoryStore {
    var records: [TranscriptRecord] = []
    var currentRecord: TranscriptRecord?
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    init() {
        setupContainer()
    }

    private func setupContainer() {
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: TranscriptRecord.self, configurations: config)
            modelContext = modelContainer?.mainContext
            fetchRecords()
        } catch {
            print("Failed to setup model container: \(error)")
        }
    }

    func fetchRecords() {
        let descriptor = FetchDescriptor<TranscriptRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        do {
            records = try modelContext?.fetch(descriptor) ?? []
        } catch {
            print("Failed to fetch records: \(error)")
        }
    }

    func startNewRecord(title: String = "") {
        let record = TranscriptRecord(date: Date(), title: title.isEmpty ? formatTitle(Date()) : title)
        currentRecord = record
        modelContext?.insert(record)
        save()
    }

    func addSegment(_ segment: TranscriptSegment) {
        guard let record = currentRecord else { return }
        var segs = record.segments
        segs.append(segment)
        record.segments = segs
        record.duration = Date().timeIntervalSince(record.date)
        save()
    }

    func stopCurrentRecord() {
        currentRecord = nil
        save()
    }

    func deleteRecord(_ record: TranscriptRecord) {
        modelContext?.delete(record)
        records.removeAll { $0.id == record.id }
        save()
    }

    func save() {
        try? modelContext?.save()
        fetchRecords()
    }

    private func formatTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}



