import SwiftUI

@MainActor
struct RecordingView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let course: Course

    private struct Segment: Identifiable {
        let id = UUID()
        let english: String
        let chinese: String
    }

    @State private var speechManager = SpeechManager()
    @State private var translationManager = TranslationManager()
    @State private var subtitleWindowController: SubtitleWindowController?
    @State private var isRecording = false
    @State private var isPaused = false
    @State private var isPreparing = false
    @State private var prepareGeneration = 0
    @State private var statusMessage = ""
    @State private var segments: [Segment] = []
    /// 上一次 final 的完整文本（用于 diff 提取新句子）
    @State private var lastFinalizedFullText = ""
    /// 当前 partial 的新部分（不含已确认的）
    @State private var currentPartialNew = ""
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var currentAccentCode = "en-GB"
    @State private var isOverlayVisible = false

    private let allAccents: [(name: String, code: String)] = [
        ("Auto (detect while recording)", "auto"),
        ("American", "en-US"),
        ("British", "en-GB"),
        ("Australian", "en-AU"),
        ("New Zealand", "en-NZ"),
        ("Irish", "en-IE"),
        ("South African", "en-ZA"),
        ("Canadian", "en-CA"),
        ("Indian", "en-IN"),
        ("Chinese", "zh-Hans"),
        ("Japanese", "ja-JP"),
        ("Korean", "ko-KR"),
    ]

    var body: some View {
        VStack(spacing: 0) { headerBar; Divider(); mainContent; Divider(); controlBar }
            .frame(minWidth: 400, minHeight: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                Task { @MainActor in
                    currentAccentCode = course.accentCode
                    speechManager.switchLanguage(to: course.accentCode)
                    setupCallbacks()
                }
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
            // 口音选择：下拉菜单（segmented 在选中值无对应分段时会布局卡死）
            Picker("Accent", selection: $currentAccentCode) {
                ForEach(allAccents, id: \.code) { accent in
                    Text(LocalizedStringKey(accent.name)).tag(accent.code)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            .disabled(isRecording || isPaused || isPreparing)
            .onChange(of: currentAccentCode) { _, newCode in
                // 录音中不切换（Auto 检测完会程序化赋值，此时识别器已经是对的）
                guard !isRecording && !isPaused else { return }
                Task { @MainActor in
                    speechManager.switchLanguage(to: newCode)
                }
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
            if segments.isEmpty && currentPartialNew.isEmpty { emptyStateView }
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
                    // 当前 partial 的新部分
                    if !currentPartialNew.isEmpty {
                        Text(currentPartialNew)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                            .id("current")
                    }
                }
                .padding()
            }
            .onChange(of: segments.count) { _, _ in
                guard autoScroll, let lastID = segments.last?.id else { return }
                // 推迟到下一个 runloop，避免在 flushTransactions/layout 期间同步滚动导致重入
                Task { @MainActor in
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }


    @AppStorage("autoScroll") private var autoScroll: Bool = true

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button(action: {
                Task { @MainActor in
                    toggleOverlay()
                }
            }) {
                Image(systemName: isOverlayVisible ? "eye.slash" : "eye")
                Text(isOverlayVisible ? "Hide Overlay" : "Show Overlay")
            }
            .buttonStyle(.bordered)
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if isRecording {
                Button(action: pauseRecording) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button(action: endRecording) {
                    Label("End Session", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else if isPreparing {
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundColor(.secondary)
            } else if isPaused {
                Button(action: resumeRecording) {
                    Label("Resume", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(action: endRecording) {
                    Label("End Session", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button(action: startRecording) {
                    Label("Start", systemImage: "mic.fill")
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

    /// 只挂回调，不创建任何 AppKit 面板。
    /// 悬浮窗改成懒加载：第一次点击 Show Overlay 才建，避免
    /// 页面 push 转场期间创建第二个 NSWindow 触发显示周期异常。
    private func setupCallbacks() {
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
        speechManager.onSegmentRecognized = { fullText, isFinal in
            Task { @MainActor in
                if isFinal {
                    // fullText 是累积全文，diff 出新句子
                    let newEnglish = self.extractNewSentence(fullText: fullText)
                    self.lastFinalizedFullText = fullText

                    guard !newEnglish.trimmingCharacters(in: .whitespaces).isEmpty else {
                        self.currentPartialNew = ""
                        return
                    }

                    // 先加标点，再翻译
                    let punctuated = await PunctuationService.punctuate(newEnglish)
                    let translated = await self.translationManager.translate(punctuated)
                    let trimmed = punctuated.trimmingCharacters(in: .whitespacesAndNewlines)

                    // 去重
                    if self.segments.last?.english != trimmed {
                        self.segments.append(Segment(english: trimmed, chinese: translated))
                        self.historyStore.addSegmentIfNew(TranscriptSegment(original: trimmed, translated: translated))
                        self.subtitleWindowController?.appendSegment(original: trimmed, translated: translated)
                    }
                    self.currentPartialNew = ""
                } else {
                    // partial 也是累积全文，diff 出当前新部分；无变化不刷新
                    let newPart = self.extractNewSentence(fullText: fullText)
                    guard newPart != self.currentPartialNew else { return }
                    self.currentPartialNew = newPart
                    self.subtitleWindowController?.updateCurrentText(newPart)
                }
            }
        }
    }

    /// 从累积全文中提取新句子（识别器会修正前面的词，不能简单 substring）
    private func extractNewSentence(fullText: String) -> String {
        guard !lastFinalizedFullText.isEmpty else { return fullText }

        // 策略1：精确前缀匹配（最常见情况）
        if fullText.hasPrefix(lastFinalizedFullText) {
            return String(fullText.dropFirst(lastFinalizedFullText.count)).trimmingCharacters(in: .whitespaces)
        }

        // 策略2：识别器修正了前面的词，找 lastFinalizedFullText 末尾与 fullText 开头的最大重叠
        let maxCheck = min(lastFinalizedFullText.count, fullText.count, 100)
        guard maxCheck >= 1 else { return fullText }
        for offset in (1...maxCheck).reversed() {
            let suffix = String(lastFinalizedFullText.suffix(offset))
            if fullText.hasPrefix(suffix) {
                return String(fullText.dropFirst(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // 策略3：完全匹配不到（识别器重置了），返回全文
        return fullText
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
                    let detected = speechManager.currentLanguageCode
                    // "auto-detect" 不在 allAccents 里，会触发布局异常；fallback 到 "auto"
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
        // 先快照 pending partial，再停录音、清状态，避免 detached Task
        // 在 dismiss 转场动画的 layout 期间回写 @State 触发约束更新重入。
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
        lastFinalizedFullText = ""

        if pendingPartial.isEmpty {
            dismiss()
        } else {
            Task { @MainActor in
                let translated = await translationManager.translate(pendingPartial)
                if segments.last?.english != pendingPartial {
                    segments.append(Segment(english: pendingPartial, chinese: translated))
                    historyStore.addSegmentIfNew(TranscriptSegment(original: pendingPartial, translated: translated))
                    subtitleWindowController?.appendSegment(original: pendingPartial, translated: translated)
                }
                // 等状态更新彻底落地，再 dismiss，避免转场 layout 期间被回写打断
                await Task.yield()
                dismiss()
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
        // 推迟到下一个 runloop，避免 NSWindow 创建/显示和 SwiftUI 布局周期重入。
        // body 只读 @State 的 isOverlayVisible，不再直接读 AppKit 的 window.isVisible。
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
}
