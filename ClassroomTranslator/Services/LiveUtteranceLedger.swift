import Foundation

/// Owns one recognition utterance. Punctuation-closed rows get stable identities
/// immediately, so later source snapshots cannot replace earlier translations.
struct LiveUtteranceLedger {
    struct Row: Equatable { let id: UUID; let original: String; let isFinal: Bool }
    struct Update { let rows: [Row]; let removedIDs: Set<UUID>; let tail: String }
    private(set) var snapshot = ""
    private(set) var rows: [Row] = []

    mutating func ingest(_ text: String, final: Bool) -> Update {
        snapshot = WhisperTranscriptAccumulator.finalCandidate(accumulated: snapshot, decoded: text)
        let units = StableSentenceUnits.split(snapshot, includeTrailingFragment: true)
        var joined: [String] = []
        for unit in units {
            if let previous = joined.last,
               let continuation = TranscriptContinuationPolicy.joined(previous: previous, incoming: unit, sameSpeaker: true, age: 0) {
                joined[joined.count - 1] = continuation
            } else { joined.append(unit) }
        }
        let oldRows = rows
        let reserved = Set(oldRows.filter { joined.contains($0.original) }.map(\.id))
        var used = Set<UUID>()
        rows = joined.enumerated().map { index, original in
            let match = oldRows.first { $0.original == original && !used.contains($0.id) }
            let fallback = index < oldRows.count && !used.contains(oldRows[index].id) && !reserved.contains(oldRows[index].id) ? oldRows[index].id : nil
            let id = match?.id ?? fallback ?? UUID()
            used.insert(id)
            return Row(id: id, original: original,
                isFinal: final || !TranscriptContinuationPolicy.needsContinuation(original))
        }
        let removed = Set(oldRows.map(\.id)).subtracting(rows.map(\.id))
        return Update(rows: rows, removedIDs: removed, tail: "")
    }

    mutating func reset() { snapshot = ""; rows.removeAll() }
}
