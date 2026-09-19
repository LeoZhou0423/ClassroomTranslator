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
    @State private var isPreparing = false
    @State private var prepareGeneration = 0
    @State private var statusMessage = ""
    /// 流式输出：累积已确认文本
    @State private var accumulatedEnglish = ""
    @State private var accumulatedChinese = ""
    /// 当前正在识别的 partial
    @State private var currentEnglish = ""
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
                // 用课程设置的口音，设置页的 Auto/手动选项只影响下载
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
            // 口音切换：Auto 模式下可快速切换
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
            if accumulatedEnglish.isEmpty && currentEnglish.isEmpty { emptyStateView }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !accumulatedEnglish.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accumulatedEnglish).font(.system(size: 14, weight: .medium))
                        if !accumulatedChinese.isEmpty {
                            Text(accumulatedChinese).font(.system(size: 13)).foregroundColor(.blue)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
                if !currentEnglish.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentEnglish).font(.system(size: 14, weight: .medium))
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                }
            }
            .padding()
        }
    }

    private var controlBar: some View {
        HStack(spacing: 20) {
            Button(action: toggleOverlay) {
                Label(subtitleWindowController?.window?.isVisible == true ? String(localized: "Hide Overlay") : String(localized: "Show Overlay"),
                      systemImage: subtitleWindowController?.window?.isVisible == true ? "eye.slash" : "eye")
            }
            .buttonStyle(.bordered)
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button(action: toggleRecording) {
                HStack {
                    if isPreparing { ProgressView().controlSize(.small) }
                    else { Image(systemName: isRecording ? "stop.fill" : "mic.fill") }
                    Text(isPreparing ? String(localized: "Preparing…") : (isRecording ? String(localized: "Stop") : String(localized: "Start")))
                }
                .frame(width: 100)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(isPreparing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func stopAndDismiss() {
        if isRecording {
            speechManager.stopRecording()
            historyStore.stopCurrentRecord()
            isRecording = false
        }
        dismiss()
    }

    private func setupSubtitleWindow() {
        let controller = SubtitleWindowController()
        subtitleWindowController = controller
        speechManager.onRecordingInterrupted = {
            Task { @MainActor in
                isRecording = false
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
                    // 累积完整 final 文本，不截取不 diff（识别器会修正前面的词）
                    accumulatedEnglish = text
                    // 整句翻译，不拼接（避免碎片翻译导致乱码）
                    let translated = await translationManager.translate(text)
                    accumulatedChinese = translated
                    // 悬浮窗：只显示这一句
                    controller.updateSegments([(original: text, translated: translated)])
                    // 保存到历史
                    historyStore.addSegment(TranscriptSegment(original: text, translated: translated))
                    currentEnglish = ""; currentChinese = ""
                } else {
                    // partial 直接全量显示（识别器每次返回从头开始的全文）
                    currentEnglish = text
                    currentChinese = ""
                    // 悬浮窗：显示 partial 原文（不翻译 partial，等 final 再翻）
                    controller.updateSegments([], currentText: text)
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            speechManager.stopRecording()
            historyStore.stopCurrentRecord()
            isRecording = false
        } else {
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
                }
            }
        }
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
