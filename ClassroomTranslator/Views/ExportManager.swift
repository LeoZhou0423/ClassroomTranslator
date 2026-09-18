import SwiftUI
import UniformTypeIdentifiers

struct ExportManager {
    static func exportSingle(record: TranscriptRecord) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Transcript")
        panel.nameFieldStringValue = "\(record.title).txt"
        panel.allowedContentTypes = [.plainText]
        
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            
            let dateLabel = String(localized: "Date:")
            let titleLabel = String(localized: "Title:")
            let durationLabel = String(localized: "Duration:")
            let content = """
            \(dateLabel) \(record.date.formatted(date: .long, time: .shortened))
            \(titleLabel) \(record.title)
            \(durationLabel) \(formatDuration(record.duration))
            
            ═══════════════════════════════════════
            
            \(record.bilingualTranscript)
            """
            
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    static func exportBatch(records: [TranscriptRecord]) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Transcripts")
        panel.nameFieldStringValue = "Transcripts_\(DateFormatter.exportFormatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            
            let headerTitle = String(localized: "Classroom Transcripts Export")
            let exportedLabel = String(localized: "Exported:")
            let dateLabel = String(localized: "Date:")
            let titleLabel = String(localized: "Title:")
            let durationLabel = String(localized: "Duration:")
            
            var content = "\(headerTitle)\n"
            content += "\(exportedLabel) \(Date().formatted(date: .long, time: .shortened))\n"
            content += String(repeating: "═", count: 50) + "\n\n"
            
            for record in records.sorted(by: { $0.date > $1.date }) {
                content += """
                \(dateLabel) \(record.date.formatted(date: .long, time: .shortened))
                \(titleLabel) \(record.title)
                \(durationLabel) \(formatDuration(record.duration))
                
                \(record.bilingualTranscript)
                
                \(String(repeating: "─", count: 50))
                
                """
            }
            
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    private static func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

extension DateFormatter {
    static let exportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter
    }()
}
