import SwiftUI

// MARK: - Segment Model

private struct Segment: Identifiable, Hashable {
    var id = UUID()
    var english: String
    var chinese: String
}

// MARK: - RecordingView (Parent)

@MainActor
struct RecordingView: View {
    @Environment(HistoryStore.self) private var historyStore
    let course: Course
    let onClose: () -> Void

    @State private var speechManager = SpeechManager()
    @State private var translationManager = TranslationManager()
    @State private var subtitleWindowController: SubtitleWindowController?
    @State private var isRecording = false
    @State private var isPaused = false
    @State private var isPreparing = false
    @State private var prepareGeneration = 0
    @State private var statusMessage = ""
    @State private var segments: [Segment] = []
    @State private var currentPartialNew = ""
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var currentAccentCode = "en-GB"
    @State private var isOverlayVisible = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBarView(
                courseName: course.name,
                currentAccentCode: currentAccentCode,
                isRecording: isRecording,
                isPaused: isPaused,
                isPreparing: isPreparing,
                onStop: stopAndDismiss,
                onHistory: { showHistory = true },
                onSettings: { showSettings = true }
            )
            Divider()
            MainContentView(
                segments: segments,
                currentPartialNew: currentPartialNew
            )
            Divider()
            ControlBarView(
                isOverlayVisible: isOverlayVisible,
                statusMessage: statusMessage,
                isRecording: isRecording,
                isPreparing: isPreparing,
                isPaused: isPaused,
                onToggleOverlay: toggleOverlay,
                onStart: startRecording,
                onPause: pauseRecording,
                onResume: resumeRecording,
                onEnd: endRecording
            )
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Task { @MainActor in
                currentAccentCode = course.accentCode
                speechManager.switchLanguage(to: course.accentCode)
                setupCallbacks()
            }
        }
        .onDisappear {
            prepareGeneration += 1
            isPreparing = false
            speechManager.stopRecording()
            historyStore.stopCurrentRecord()
            speechManager.onRecordingInterrupted = nil
            speechManager.onLanguageModelStatusChanged = nil
            speechManager.onSegmentRecognized = nil
        }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showSettings) { SettingsView(translationManager: translationManager) }
        .modifier(TranslationSessionCompat(manager: translationManager))
    }

    // MARK: - Actions

    private func stopAndDismiss() {
        prepareGeneration += 1
        isPreparing = false
        speechManager.stopRecording()
        if isRecording || isPaused {
            historyStore.stopCurrentRecord()
            isRecording = false
            isPaused = false
        }
        onClose()
    }

    private func setupCallbacks() {
        speechManager.onRecordingInterrupted = {
            prepareGeneration += 1
            isPreparing = false
            isRecording = false
            isPaused = false
            statusMessage = String(localized: "Recording was interrupted. Tap Start to resume.")
        }
        speechManager.onLanguageModelStatusChanged = { message in
            Task { @MainActor in
                statusMessage = message
            }
        }
        speechManager.onSegmentRecognized = { text, isFinal in
            Task { @MainActor in
                if isFinal {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        self.currentPartialNew = ""
                        return
                    }
                    let sentence = Self.ensureEndingPunctuation(trimmed)
                    let translated = await self.translationManager.translate(sentence)
                    self.segments.append(Segment(english: sentence, chinese: translated))
                    self.historyStore.addSegmentIfNew(TranscriptSegment(original: sentence, translated: translated))
                    self.subtitleWindowController?.appendSegment(original: sentence, translated: translated)
                    self.currentPartialNew = ""
                } else {
                    guard text != self.currentPartialNew else { return }
                    self.currentPartialNew = text
                    let lastChinese = self.segments.last?.chinese ?? ""
                    self.subtitleWindowController?.updateCurrentText(original: text, translated: lastChinese)
                }
            }
        }
    }

    /// 本地分句 + 标点修正（不依赖 rpunct）
    private static func ensureEndingPunctuation(_ text: String) -> String {
        var result = fixInternalPunctuation(text)
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return result }
        if ".!?。！？…".contains(last) { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("what") || lower.hasPrefix("how") || lower.hasPrefix("why")
            || lower.hasPrefix("where") || lower.hasPrefix("when") || lower.hasPrefix("who")
            || lower.hasPrefix("can ") || lower.hasPrefix("could ") || lower.hasPrefix("would")
            || lower.hasPrefix("is ") || lower.hasPrefix("are ") || lower.hasPrefix("do ")
            || lower.hasPrefix("does ") || lower.hasPrefix("did ") {
            return trimmed + "?"
        }
        return trimmed + "."
    }

    /// 把不该是逗号的地方改成句号
    private static func fixInternalPunctuation(_ text: String) -> String {
        let conjunctions = ["and ", "but ", "so ", "or ", "yet ", "because ", "although ",
                            "while ", "when ", "if ", "then ", "therefore ", "however ",
                            "moreover ", "furthermore ", "nevertheless ", "also "]
        var result = text
        for conj in conjunctions {
            let pattern = ", " + conj
            while let range = result.range(of: pattern, options: .caseInsensitive) {
                let afterConj = result[range.upperBound...]
                let words = afterConj.prefix(while: { !$0.isNewline && $0 != "." && $0 != "!" && $0 != "?" })
                if words.split(separator: " ").count >= 2 {
                    result.replaceSubrange(range.lowerBound..<range.upperBound, with: ". " + conj)
                } else {
                    break
                }
            }
        }
        return result
    }

    private func startRecording() {
        guard !isPreparing, !isRecording else { return }
        speechManager.switchLanguage(to: currentAccentCode)
        prepareGeneration += 1
        let generation = prepareGeneration
        isPreparing = true
        Task {
            defer { if generation == prepareGeneration { isPreparing = false } }
            statusMessage = String(localized: "Requesting speech recognition permission…")
            let speechErr = await runStep(timeoutMessage: String(localized: "Speech recognition permission timed out.")) {
                guard await speechManager.requestSpeechPermission() else { throw SpeechError.permissionDeniedSpeech }
            }
            guard generation == prepareGeneration else { return }
            if let speechErr {
                statusMessage = Self.message(for: speechErr, fallback: String(localized: "Speech recognition permission was denied."))
                return
            }
            statusMessage = String(localized: "Requesting microphone permission…")
            let micErr = await runStep(timeoutMessage: String(localized: "Microphone permission timed out.")) {
                guard await speechManager.requestMicPermission() else { throw SpeechError.permissionDeniedMic }
            }
            guard generation == prepareGeneration else { return }
            if let micErr {
                statusMessage = Self.message(for: micErr, fallback: String(localized: "Microphone permission was denied."))
                return
            }
            if currentAccentCode == "auto" {
                statusMessage = String(localized: "Starting recording…")
                let detectErr = await runStep(timeoutSeconds: 30, timeoutMessage: String(localized: "Accent detection timed out.")) {
                    try await speechManager.startAutoDetectRecording()
                }
                guard generation == prepareGeneration else { return }
                if let detectErr {
                    statusMessage = Self.message(for: detectErr, fallback: String(localized: "Failed to start recording."))
                } else {
                    let detected = speechManager.currentLanguageCode
                    let allAccents = HeaderBarView.allAccents
                    currentAccentCode = allAccents.contains(where: { $0.code == detected }) ? detected : "auto"
                    historyStore.startNewRecord(in: course)
                    statusMessage = ""
                    isRecording = true
                    isPaused = false
                }
            } else {
                statusMessage = String(localized: "Starting recording…")
                let startErr = await runStep(timeoutSeconds: 20, timeoutMessage: String(localized: "Recording took too long to start.")) {
                    try await speechManager.startRecording()
                }
                guard generation == prepareGeneration else { return }
                if let startErr {
                    statusMessage = Self.message(for: startErr, fallback: String(localized: "Failed to start recording."))
                } else {
                    historyStore.startNewRecord(in: course)
                    statusMessage = ""
                    isRecording = true
                    isPaused = false
                }
            }
        }
    }

    private func pauseRecording() {
        speechManager.stopRecording()
        isRecording = false
        isPaused = true
        statusMessage = String(localized: "Recording paused")
    }

    private func resumeRecording() {
        guard !isPreparing, !isRecording else { return }
        prepareGeneration += 1
        let generation = prepareGeneration
        isPreparing = true
        Task {
            defer { if generation == prepareGeneration { isPreparing = false } }
            statusMessage = String(localized: "Starting recording…")
            let startErr = await runStep(timeoutSeconds: 20, timeoutMessage: String(localized: "Recording took too long to start.")) {
                try await speechManager.startRecording()
            }
            guard generation == prepareGeneration else { return }
            if let startErr {
                statusMessage = Self.message(for: startErr, fallback: String(localized: "Failed to start recording."))
            } else {
                statusMessage = ""
                isRecording = true
                isPaused = false
            }
        }
    }

    private func endRecording() {
        let pendingPartial = currentPartialNew.trimmingCharacters(in: .whitespacesAndNewlines)
        if speechManager.currentLanguageCode == "auto-detect" {
            speechManager.stopAutoDetectRecording()
        } else {
            speechManager.stopRecording()
        }
        historyStore.stopCurrentRecord()
        isRecording = false
        isPaused = false
        currentPartialNew = ""
        if pendingPartial.isEmpty {
            onClose()
        } else {
            Task { @MainActor in
                let translated = await translationManager.translate(pendingPartial)
                if segments.last?.english != pendingPartial {
                    segments.append(Segment(english: pendingPartial, chinese: translated))
                    historyStore.addSegmentIfNew(TranscriptSegment(original: pendingPartial, translated: translated))
                    subtitleWindowController?.appendSegment(original: pendingPartial, translated: translated)
                }
                await Task.yield()
                onClose()
            }
        }
    }

    private func toggleOverlay() {
        DispatchQueue.main.async { [self] in
            if subtitleWindowController == nil {
                subtitleWindowController = SubtitleWindowController()
            }
            if subtitleWindowController?.window?.isVisible == true {
                subtitleWindowController?.hideWindow()
                isOverlayVisible = false
            } else {
                DispatchQueue.main.async {
                    self.subtitleWindowController?.showWindow()
                    self.isOverlayVisible = true
                }
            }
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(fallback) (\(error.localizedDescription))"
    }

    private func runStep(timeoutSeconds: UInt64 = 25, timeoutMessage: String, operation: @escaping @MainActor () async throws -> Void) async -> Error? {
        let generation = prepareGeneration
        return await RecordingStartupStep.run(
            timeoutNanoseconds: timeoutSeconds * 1_000_000_000,
            onTimeout: {
                guard generation == prepareGeneration else { return }
                prepareGeneration += 1
                speechManager.stopRecording()
                statusMessage = timeoutMessage
                isPreparing = false
            },
            operation: operation
        )
    }

}

// MARK: - HeaderBarView (独立 view graph)

private struct HeaderBarView: View {
    let courseName: String
    let currentAccentCode: String
    let isRecording: Bool
    let isPaused: Bool
    let isPreparing: Bool
    let onStop: () -> Void
    let onHistory: () -> Void
    let onSettings: () -> Void

    static let allAccents: [(name: String, code: String)] = [
        ("Auto (detect while recording)", "auto"),
        ("American", "en-US"), ("British", "en-GB"), ("Australian", "en-AU"),
        ("New Zealand", "en-NZ"), ("Irish", "en-IE"), ("South African", "en-ZA"),
        ("Canadian", "en-CA"), ("Indian", "en-IN"), ("Chinese", "zh-Hans"),
        ("Japanese", "ja-JP"), ("Korean", "ko-KR"),
    ]

    var body: some View {
        HStack {
            Button(action: onStop) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            Text(courseName).font(.headline)
            Text(Self.allAccents.first(where: { $0.code == currentAccentCode })?.name ?? currentAccentCode)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: onHistory) { Label("History", systemImage: "clock") }.buttonStyle(.borderless)
            Button(action: onSettings) { Label("Settings", systemImage: "gear") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - MainContentView (独立 view graph)

private struct MainContentView: View {
    let segments: [Segment]
    let currentPartialNew: String

    var body: some View {
        VStack(spacing: 16) {
            if segments.isEmpty && currentPartialNew.isEmpty {
                EmptyStateView()
            } else {
                TranscriptView(segments: segments, currentPartialNew: currentPartialNew)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - EmptyStateView (独立 view graph)

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle").font(.system(size: 60)).foregroundColor(.secondary)
            Text("Ready to Listen").font(.title2).foregroundColor(.secondary)
            Text("Click Start to begin recording").font(.subheadline).foregroundColor(.secondary)
        }
    }
}

// MARK: - TranscriptView (独立 view graph)

private struct TranscriptView: View {
    let segments: [Segment]
    let currentPartialNew: String
    @AppStorage("autoScroll") private var autoScroll: Bool = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(segments) { seg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(seg.english)
                                .font(.system(size: 14, weight: .medium))
                            Text(seg.chinese)
                                .font(.system(size: 14))
                                .foregroundColor(.blue)
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    Text(currentPartialNew)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                        .padding(currentPartialNew.isEmpty ? 0 : 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            currentPartialNew.isEmpty
                                ? Color.clear
                                : Color(nsColor: .controlBackgroundColor).opacity(0.5)
                        )
                        .cornerRadius(8)
                        .opacity(currentPartialNew.isEmpty ? 0 : 1)
                        .frame(height: currentPartialNew.isEmpty ? 0 : nil)
                        .clipped()
                        .animation(.easeInOut(duration: 0.1), value: currentPartialNew)
                        .id("current")
                }
                .padding()
            }
            .onChange(of: segments.count) { _, _ in
                guard autoScroll, let lastID = segments.last?.id else { return }
                Task { @MainActor in
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - ControlBarView (独立 view graph)

private struct ControlBarView: View {
    let isOverlayVisible: Bool
    let statusMessage: String
    let isRecording: Bool
    let isPreparing: Bool
    let isPaused: Bool
    let onToggleOverlay: () -> Void
    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onToggleOverlay) {
                Image(systemName: isOverlayVisible ? "eye.slash" : "eye")
                Text(isOverlayVisible ? "Hide Overlay" : "Show Overlay")
            }
            .buttonStyle(.bordered)
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if isRecording {
                Button(action: onPause) { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(.bordered).controlSize(.large)
                Button(action: onEnd) { Label("End Session", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else if isPreparing {
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundColor(.secondary)
            } else if isPaused {
                Button(action: onResume) { Label("Resume", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button(action: onEnd) { Label("End Session", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else {
                Button(action: onStart) { Label("Start", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
