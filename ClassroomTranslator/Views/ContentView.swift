import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(HistoryStore.self) private var historyStore
    @State private var speechManager = SpeechManager()
    @State private var translationManager = TranslationManager()
    @State private var subtitleWindowController: SubtitleWindowController?
    @State private var isRecording = false
    @State private var isPreparing = false
    @State private var prepareGeneration = 0
    @State private var statusMessage = ""
    @State private var currentEnglish = ""
    @State private var currentChinese = ""
    @State private var recentSegments: [(original: String, translated: String)] = []
    @State private var showHistory = false
    @State private var showSettings = false
    @AppStorage("recognitionLanguage") private var recognitionLanguage: String = "auto"
    private let maxRecentSegments = 20

    var body: some View {
        VStack(spacing: 0) { headerBar; Divider(); mainContent; Divider(); controlBar }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            applyAutoLanguage()
            setupSubtitleWindow()
        }
        .onChange(of: recognitionLanguage) { _, newLanguage in
            applyAutoLanguage()
            speechManager.switchLanguage(to: effectiveLanguage)
        }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showSettings) { SettingsView(translationManager: translationManager) }
        .modifier(TranslationSessionCompat(manager: translationManager))
    }
    
    private var headerBar: some View {
        HStack {
            Image(systemName: "text.book.closed").font(.title2).foregroundColor(.accentColor)
            Text("Classroom Translator").font(.headline)
            Text("(\(currentAccentName))").font(.caption).foregroundColor(.secondary)
            Spacer()
            Button(action: { showHistory = true }) { Label("History", systemImage: "clock") }.buttonStyle(.borderless)
            Button(action: { showSettings = true }) { Label("Settings", systemImage: "gear") }.buttonStyle(.borderless)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    
    private var mainContent: some View {
        VStack(spacing: 16) {
            if recentSegments.isEmpty && currentEnglish.isEmpty { emptyStateView }
            else { transcriptView }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
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
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(recentSegments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(segment.original).font(.system(size: 14, weight: .medium))
                        Text(segment.translated).font(.system(size: 13)).foregroundColor(.blue)
                    }.padding(8).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(6)
                }
                if !currentEnglish.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentEnglish).font(.system(size: 14, weight: .medium)).foregroundColor(.orange)
                        Text(currentChinese.isEmpty ? String(localized: "Translating...") : currentChinese).font(.system(size: 13)).foregroundColor(.gray)
                    }.padding(8).background(Color(nsColor: .controlBackgroundColor).opacity(0.5)).cornerRadius(6)
                }
            }.padding()
        }
    }
    
    private var controlBar: some View {
        HStack(spacing: 20) {
            Button(action: toggleOverlay) {
                Label(subtitleWindowController?.window?.isVisible == true ? String(localized: "Hide Overlay") : String(localized: "Show Overlay"),
                      systemImage: subtitleWindowController?.window?.isVisible == true ? "eye.slash" : "eye")
            }.buttonStyle(.bordered)
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
            }.buttonStyle(.borderedProminent).tint(isRecording ? .red : .accentColor).controlSize(.large)
            .disabled(isPreparing)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    
    private var currentAccentName: String {
        let accentMap: [String: String] = [
            "en-US": "American", "en-GB": "British", "en-AU": "Australian",
            "en-IN": "Indian", "en-IE": "Irish", "en-NZ": "New Zealand",
            "en-ZA": "South African", "zh-Hans": "Chinese",
            "ja-JP": "Japanese", "ko-KR": "Korean", "hi-IN": "Hindi"
        ]
        let code = effectiveLanguage
        let name = accentMap[code] ?? code
        return NSLocalizedString(name, comment: "Speech accent display name")
    }

    /// 当前实际使用的语言代码（"auto" 时解析为系统语言）
    private var effectiveLanguage: String {
        if recognitionLanguage != "auto" { return recognitionLanguage }
        return Self.detectLanguageFromSystem()
    }

    private func applyAutoLanguage() {
        if recognitionLanguage != "auto" {
            speechManager.switchLanguage(to: recognitionLanguage)
        } else {
            speechManager.switchLanguage(to: Self.detectLanguageFromSystem())
        }
    }

    /// 根据系统语言自动匹配最佳识别器
    private static func detectLanguageFromSystem() -> String {
        let sysLang = Locale.preferredLanguages.first ?? "en-US"
        // 精确匹配
        let supported = Set([
            "en-US", "en-GB", "en-AU", "en-NZ", "en-IE", "en-ZA", "en-CA",
            "en-IN", "en-PH", "en-SG", "en-MY", "en-JP", "en-KR",
            "en-AE", "en-SA", "en-IL", "en-TR", "en-EG", "en-QA",
            "en-KW", "en-BH", "en-OM", "en-JO", "en-LB",
            "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "hi-IN"
        ])
        if supported.contains(sysLang) { return sysLang }
        // 前缀匹配 (en-US-xx → en-US)
        let prefix = String(sysLang.prefix(5))
        if supported.contains(prefix) { return prefix }
        // 语言族匹配 (en → en-US)
        let lang = String(sysLang.prefix(2))
        if lang == "en" { return "en-US" }
        if lang == "zh" { return "zh-Hans" }
        if lang == "ja" { return "ja-JP" }
        if lang == "ko" { return "ko-KR" }
        if lang == "hi" { return "hi-IN" }
        return "en-US" // 兜底
    }
    
    private func setupSubtitleWindow() {
        let controller = SubtitleWindowController()
        subtitleWindowController = controller
        speechManager.onRecordingInterrupted = {
            Task { @MainActor in
                isRecording = false
                statusMessage = String(localized: "Recording was interrupted (e.g. screen lock or audio device change). Tap Start to resume.")
            }
        }
        speechManager.onSegmentRecognized = { text, isFinal in
            Task { @MainActor in
                if isFinal {
                    recentSegments.append((original: text, translated: ""))
                    if recentSegments.count > maxRecentSegments { recentSegments.removeFirst() }
                    let translated = await translationManager.translate(text)
                    if let lastIndex = recentSegments.indices.last {
                        recentSegments[lastIndex] = (original: text, translated: translated)
                    }
                    controller.updateSegments(recentSegments)
                    historyStore.addSegment(TranscriptSegment(original: text, translated: translated))
                    currentEnglish = ""; currentChinese = ""
                } else {
                    currentEnglish = text
                    controller.updateSegments(recentSegments, currentText: text)
                }
            }
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            speechManager.stopRecording(); historyStore.stopCurrentRecord(); isRecording = false
        } else {
            // 先亮状态再干活：首次会弹授权框、下语音模型，不再看着像卡死
            prepareGeneration += 1
            let generation = prepareGeneration
            isPreparing = true
            Task {
                defer { if generation == prepareGeneration { isPreparing = false } }
                // 1. 语音识别权限（走苹果服务器，国内慢时这一步最久）
                statusMessage = String(localized: "Requesting speech recognition permission…")
                let speechErr = await runStep(timeoutMessage: String(localized: "Speech recognition permission request timed out. Please allow access in System Settings → Privacy & Security → Speech Recognition, then try again.")) {
                    guard await speechManager.requestSpeechPermission() else {
                        throw SpeechError.permissionDeniedSpeech
                    }
                }
                guard generation == prepareGeneration else { return }
                if let speechErr {
                    statusMessage = Self.message(for: speechErr, fallback: String(localized: "Speech recognition permission was denied. Please allow it in System Settings → Privacy & Security → Speech Recognition, then try again."))
                    return
                }
                // 2. 麦克风权限
                statusMessage = String(localized: "Requesting microphone permission…")
                let micErr = await runStep(timeoutMessage: String(localized: "Microphone permission request timed out. Please allow access in System Settings → Privacy & Security → Microphone, then try again.")) {
                    guard await speechManager.requestMicPermission() else {
                        throw SpeechError.permissionDeniedMic
                    }
                }
                guard generation == prepareGeneration else { return }
                if let micErr {
                    statusMessage = Self.message(for: micErr, fallback: String(localized: "Microphone permission was denied. Please allow it in System Settings → Privacy & Security → Microphone, then try again."))
                    return
                }
                // 3. 启动（引擎启动可能因残留状态/麦克风被占用而阻塞，加看门狗）
                statusMessage = String(localized: "Starting recording…")
                let startErr = await runStep(timeoutSeconds: 20, timeoutMessage: String(localized: "Recording took too long to start. Another app may be using the microphone. Stop it and try again.")) {
                    try await speechManager.startRecording()
                }
                guard generation == prepareGeneration else { return }
                if let startErr {
                    statusMessage = Self.message(for: startErr, fallback: String(localized: "Failed to start recording. Please check the microphone and try again."))
                } else {
                    historyStore.startNewRecord()
                    statusMessage = ""
                    isRecording = true
                }
            }
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? SpeechError)?.errorDescription ?? fallback
    }

    /// 跑一步可能卡住的操作。超时只改提示并放开按钮让用户重试，
    /// 不强杀（授权回调丢了的话杀也没用）；用 generation 丢弃过期任务。
    /// 返回 nil=成功，否则是具体错误（超时由看门狗单独提示，这里不返回）。
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
}
