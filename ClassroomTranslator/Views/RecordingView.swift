import SwiftUI

@MainActor
struct RecordingView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let course: Course

    @State private var speechManager = SpeechManager()
    @State private var translationManager = TranslationManager()
    @State private var subtitleWindowController: SubtitleWindowController?
    @State private var isRecording = false
    @State private var isPaused = false
    @State private var isPreparing = false
    @State private var prepareGeneration = 0
    @State private var statusMessage = ""
    /// 已确认的翻译段落（只存中文）
    @State private var translatedSegments: [String] = []
    /// 当前正在识别的 partial 英文（overlay 显示用）
    @State private var currentEnglish = ""
    /// 当前 partial 的翻译
    @State private var currentChinese = ""
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var currentAccentCode = "en-GB"
    @AppStorage("recognitionLanguage") private var recognitionLanguage: String = "auto"

    private let quickAccents = ["en-US", "en-GB", "en-AU", "en-IN", "zh-Hans"]

    var body: some View {
        VStack(spacing: 0) { headerBar; Divider(); mainContent; Divider(); controlBar }
            .frame(minWidth: 400, minHeight: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                currentAccentCode = course.accentCode
                speechManager.switchLanguage(to: course.accentCode)
                setupSubtitleWindow()
            }
            .sheet(isPresented: $showHistory) { HistoryView() }
            .sheet(isPresented: $showSettings) { SettingsView(translationManager: translationManager) }
            .modifier(TranslationSessionCompat(manager: translationManager))
    }

    private var headerBar: some View {
        HStack {
            Button(action: { stopAndDismiss() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            Text(course.name).font(.headline)
            if recognitionLanguage == "auto" {
                Picker("Accent", selection: $currentAccentCode) {
                    ForEach(quickAccents, id: \.self) { code in
                        Text(shortAccentName(code)).tag(code)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .onChange(of: currentAccentCode) { _, newCode in
                    speechManager.switchLanguage(to: newCode)
                }
            } else {
                Text("(\(course.accentName))").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { showHistory = true }) { Label("History", systemImage: "clock") }.buttonStyle(.borderless)
            Button(action: { showSettings = true }) { Label("Settings", systemImage: "gear") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var mainContent: some View {
        VStack(spacing: 16) {
            if translatedSegments.isEmpty && currentEnglish.isEmpty { emptyStateView }
            else { transcriptView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle").font(.system(size: 60)).foregroundColor(.secondary)
            Text("Ready to Listen").font(.title2).foregroundColor(.secondary)
            Text("Click Start to begin recording").font(.subheadline).foregroundColor(.secondary)
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // 已确认的翻译段落（只显示中文）
                    ForEach(Array(translatedSegments.enumerated()), id: \.offset) { index, chinese in
                        Text(chinese)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                            .id(index)
                    }
                    // 当前 partial 的翻译（实时）
                    if !currentChinese.isEmpty {
                        Text(currentChinese)
                            .font(.system(size: 15))
                            .foregroundColor(.blue)
                            .padding(10)
                            .background(Color.blue.opacity(0.08))
                            .cornerRadius(8)
                            .id("current")
                    }
                }
                .padding()
            }
            .onChange(of: translatedSegments.count) { _, _ in
                if autoScroll { withAnimation { proxy.scrollTo(translatedSegments.count - 1, anchor: .bottom) } }
            }
        }
    }

    @AppStorage("autoScroll") private var autoScroll: Bool = true

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button(action: toggleOverlay) {
                Label(subtitleWindowController?.window?.isVisible == true ? String(localized: "Hide Overlay") : String(localized: "Show Overlay"),
                      systemImage: subtitleWindowController?.window?.isVisible == true ? "eye.slash" : "eye")
            }
            .buttonStyle(.bordered)
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if isRecording {
                Button(action: pauseRecording) {
                    Label(String(localized: "Pause"), systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button(action: endRecording) {
                    Label(String(localized: "End Session"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else if isPreparing {
                ProgressView().controlSize(.small)
                Text(String(localized: "Preparing…")).foregroundColor(.secondary)
            } else if isPaused {
                Button(action: resumeRecording) {
                    Label(String(localized: "Resume"), systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(action: endRecording) {
                    Label(String(localized: "End Session"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button(action: startRecording) {
                    Label(String(localized: "Start"), systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func stopAndDismiss() {
        if isRecording || isPaused {
            speechManager.stopRecording()
            historyStore.stopCurrentRecord()
            isRecording = false
            isPaused = false
        }
        dismiss()
    }

    private func setupSubtitleWindow() {
        let controller = SubtitleWindowController()
        subtitleWindowController = controller
        speechManager.onRecordingInterrupted = {
            Task { @MainActor in
                isRecording = false
                isPaused = false
                statusMessage = String(localized: "Recording was interrupted. Tap Start to resume.")
            }
        }
        speechManager.onLanguageModelStatusChanged = { message in
            Task { @MainActor in
                statusMessage = message
            }
        }
        speechManager.onSegmentRecognized = { text, isFinal in
            Task { @MainActor in
                if isFinal {
                    // 整句翻译
                    let translated = await translationManager.translate(text)
                    // 去重：如果最后一段和当前一样就不追加
                    if translatedSegments.last != translated {
                        translatedSegments.append(translated)
                    }
                    // 保存到历史（去重）
                    historyStore.addSegmentIfNew(TranscriptSegment(original: text, translated: translated))
                    // overlay 追加
                    controller.appendSegment(original: text, translated: translated)
                    currentEnglish = ""
                    currentChinese = ""
                } else {
                    currentEnglish = text
                    // partial 不翻译，直接用英文原文在 overlay 显示
                    controller.updateCurrentText(text)
                }
            }
        }
    }

    private func startRecording() {
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
                statusMessage = String(localized: "Detecting accent…")
                let detectErr = await runStep(timeoutSeconds: 30, timeoutMessage: String(localized: "Accent detection timed out.")) {
                    try await speechManager.startAutoDetectRecording()
                }
                guard generation == prepareGeneration else { return }
                if let detectErr {
                    statusMessage = Self.message(for: detectErr, fallback: String(localized: "Failed to start recording."))
                } else {
                    currentAccentCode = speechManager.currentLanguageCode
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
        if speechManager.currentLanguageCode == "auto-detect" {
            speechManager.stopAutoDetectRecording()
        } else {
            speechManager.stopRecording()
        }
        // 翻译最后一段 partial（如果有）
        if !currentEnglish.isEmpty {
            Task {
                let translated = await translationManager.translate(currentEnglish)
                if translatedSegments.last != translated {
                    translatedSegments.append(translated)
                }
                historyStore.addSegmentIfNew(TranscriptSegment(original: currentEnglish, translated: translated))
                subtitleWindowController?.appendSegment(original: currentEnglish, translated: translated)
            }
        }
        historyStore.stopCurrentRecord()
        isRecording = false
        isPaused = false
        currentEnglish = ""
        currentChinese = ""
        dismiss()
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? SpeechError)?.errorDescription ?? fallback
    }

    private func runStep(timeoutSeconds: UInt64 = 25, timeoutMessage: String, operation: () async throws -> Void) async -> Error? {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            if !Task.isCancelled {
                statusMessage = timeoutMessage
                isPreparing = false
            }
        }
        do {
            try await operation()
            watchdog.cancel()
            return nil
        } catch {
            watchdog.cancel()
            return error
        }
    }

    private func toggleOverlay() {
        if subtitleWindowController?.window?.isVisible == true { subtitleWindowController?.hideWindow() }
        else { subtitleWindowController?.showWindow() }
    }

    private func shortAccentName(_ code: String) -> String {
        let map = ["en-US": "US", "en-GB": "UK", "en-AU": "AU", "en-IN": "IN", "zh-Hans": "中"]
        return map[code] ?? code
    }
}
