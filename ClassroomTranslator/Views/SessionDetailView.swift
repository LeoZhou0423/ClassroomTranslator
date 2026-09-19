import SwiftUI

struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: TranscriptRecord

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(record.title).font(.headline)
                Spacer()
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundColor(.secondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(record.segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(segment.original)
                                .font(.system(size: 14, weight: .medium))
                            Text(segment.translated)
                                .font(.system(size: 13))
                                .foregroundColor(.blue)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Text("\(record.segments.count) segments")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: exportTranscript) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func exportTranscript() {
        let content = record.bilingualTranscript
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(record.title).txt"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
