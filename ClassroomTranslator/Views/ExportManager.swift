import SwiftUI
import UniformTypeIdentifiers

struct ExportManager {
    enum ExportError: LocalizedError {
        case unableToCreateDocument
        case archiveFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unableToCreateDocument: return String(localized: "Unable to create the Word document.")
            case .archiveFailed: return String(localized: "Unable to package the Word document.")
            case .cancelled: return String(localized: "Export cancelled.")
            }
        }
    }

    /// UX-07 / PSY-04：用户主动取消永远不算错误。
    /// 调用方用它把"取消"从 alert / footer 错误态里摘出去。
    static func isCancellation(_ error: Error) -> Bool {
        guard let exportError = error as? ExportError else { return false }
        if case .cancelled = exportError { return true }
        return false
    }

    static func exportSingle(record: TranscriptRecord, completion: ((Result<URL, Error>) -> Void)? = nil) {
        // NSSavePanel.begin 是非模态的：面板开着的时候用户可以删掉这条记录，
        // 回调里再访问 record 会命中"backing data could no longer be found"的
        // SwiftData fatal error。所以在打开面板前把内容一次性取出来。
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

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Transcript")
        panel.nameFieldStringValue = "\(record.title).txt"
        panel.allowedContentTypes = [.plainText]

        panel.begin { result in
            guard result == .OK, let url = panel.url else {
                completion?(.failure(ExportError.cancelled))
                return
            }
            
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                completion?(.success(url))
            } catch {
                completion?(.failure(error))
            }
        }
    }
    
    static func exportBatch(records: [TranscriptRecord], completion: ((Result<URL, Error>) -> Void)? = nil) {
        // 同 exportSingle：面板非模态，先取快照避免回调里访问已被删除的 SwiftData 对象。
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

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Transcripts")
        panel.nameFieldStringValue = "Transcripts_\(DateFormatter.exportFormatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]

        panel.begin { result in
            guard result == .OK, let url = panel.url else {
                completion?(.failure(ExportError.cancelled))
                return
            }
            
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                completion?(.success(url))
            } catch {
                completion?(.failure(error))
            }
        }
    }

    static func exportWord(record: TranscriptRecord, completion: ((Result<URL, Error>) -> Void)? = nil) {
        // 快照必须在打开面板之前取：见 exportSingle 的说明。
        let snapshot = WordSnapshot(
            title: record.title,
            courseName: record.course?.name ?? "",
            date: record.date,
            duration: record.duration,
            segments: record.segments
        )

        let panel = NSSavePanel()
        panel.title = String(localized: "Export as Word")
        panel.nameFieldStringValue = "\(safeFilename(record.title)).docx"
        if let wordType = UTType(filenameExtension: "docx") {
            panel.allowedContentTypes = [wordType]
        }
        panel.begin { result in
            guard result == .OK, let url = panel.url else {
                completion?(.failure(ExportError.cancelled))
                return
            }
            Task.detached {
                do {
                    try createWordDocument(snapshot: snapshot, at: url)
                    await MainActor.run { completion?(.success(url)) }
                } catch {
                    await MainActor.run { completion?(.failure(error)) }
                }
            }
        }
    }

    private struct WordSnapshot: Sendable {
        let title: String
        let courseName: String
        let date: Date
        let duration: TimeInterval
        let segments: [TranscriptSegment]
    }

    private static func createWordDocument(snapshot: WordSnapshot, at destination: URL) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LingoClassWord-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let rels = root.appendingPathComponent("_rels", isDirectory: true)
        let word = root.appendingPathComponent("word", isDirectory: true)
        let wordRels = word.appendingPathComponent("_rels", isDirectory: true)
        try fm.createDirectory(at: rels, withIntermediateDirectories: true)
        try fm.createDirectory(at: word, withIntermediateDirectories: true)
        try fm.createDirectory(at: wordRels, withIntermediateDirectories: true)

        try contentTypesXML.write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try packageRelationshipsXML.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try stylesXML.write(to: word.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)
        try documentRelationshipsXML.write(to: wordRels.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
        try documentXML(snapshot).write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-X", "-q", "-r", destination.path, "."]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
            throw ExportError.archiveFailed
        }
    }

    private static func documentXML(_ snapshot: WordSnapshot) -> String {
        var body = paragraph(snapshot.title, style: "Title")
        if !snapshot.courseName.isEmpty {
            body += paragraph(snapshot.courseName, style: "Subtitle")
        }
        body += paragraph("\(String(localized: "Date:")) \(snapshot.date.formatted(date: .long, time: .shortened))", style: "Metadata")
        body += paragraph("\(String(localized: "Duration:")) \(formatDuration(snapshot.duration))", style: "Metadata")
        body += paragraph(String(localized: "Transcript"), style: "Heading1")
        for segment in snapshot.segments {
            // task-4：Word 导出同样走 SpeakerLabels 统一前缀（与 TXT/转写一致）。
            body += paragraph(segment.speakerLinePrefix + segment.original, style: "Original")
            if !segment.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body += paragraph(segment.translated, style: "Translation")
            }
        }
        if snapshot.segments.isEmpty {
            body += paragraph(String(localized: "No transcript content."), style: "Metadata")
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(body)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body></w:document>
        """
    }

    private static func paragraph(_ text: String, style: String) -> String {
        let lines = xmlEscape(text).replacingOccurrences(of: "\n", with: "</w:t><w:br/><w:t xml:space=\"preserve\">")
        return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(lines)</w:t></w:r></w:p>"
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Transcript" : parts.joined(separator: "-")
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    </Types>
    """

    private static let packageRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:eastAsia="PingFang SC"/><w:sz w:val="22"/><w:color w:val="000000"/></w:rPr><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="000000"/></w:rPr><w:pPr><w:spacing w:after="240"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="24"/><w:color w:val="555555"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Metadata"><w:name w:val="Metadata"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="19"/><w:color w:val="666666"/></w:rPr><w:pPr><w:spacing w:after="80"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="000000"/></w:rPr><w:pPr><w:spacing w:before="360" w:after="180"/><w:keepNext/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Original"><w:name w:val="Original"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:color w:val="000000"/></w:rPr><w:pPr><w:spacing w:before="160" w:after="70"/><w:keepNext/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Translation"><w:name w:val="Translation"/><w:basedOn w:val="Normal"/><w:rPr><w:color w:val="245A9A"/></w:rPr><w:pPr><w:spacing w:after="220"/></w:pPr></w:style>
    </w:styles>
    """
    
    // 不标 private：VIS-09 的格式统一属纯逻辑，ExportFormatTests 直接回归它。
    static func formatDuration(_ duration: TimeInterval) -> String {
        // VIS-09：统一 h:mm:ss，与录音页计时器、历史列表一致。
        let total = max(0, Int(duration))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

extension DateFormatter {
    static let exportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter
    }()
}
