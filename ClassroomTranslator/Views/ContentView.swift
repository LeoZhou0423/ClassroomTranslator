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
    @AppStorage("recognitionLanguage") private var recognitionLanguage: String = "en-GB"
    private let maxRecentSegments = 20

    var body: some View {
        VStack(spacing: 0) { headerBar; Divider(); mainContent; Divider(); controlBar }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { setupSubtitleWindow() }
        .onChange(of: recognitionLanguage) { _, newLanguage in
            speechManager.switchLanguage(to: newLanguage)
        }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
        let name = accentMap[recognitionLanguage] ?? recognitionLanguage
        return NSLocalizedString(name, comment: "Speech accent display name")
    }
    
    private func setupSubtitleWindow() {
        let controller = SubtitleWindowController()
        subtitleWindowController = controller
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
                let speechOK = await runStep(timeoutMessage: String(localized: "Speech recognition permission request timed out. Please allow access in System Settings → Privacy & Security → Speech Recognition, then try again.")) {
                    await speechManager.requestSpeechPermission()
                }
                guard generation == prepareGeneration else { return }
                guard speechOK else {
                    statusMessage = String(localized: "Speech recognition permission was denied. Please allow it in System Settings → Privacy & Security → Speech Recognition, then try again.")
                    return
                }
                // 2. 麦克风权限
                statusMessage = String(localized: "Requesting microphone permission…")
                let micOK = await runStep(timeoutMessage: String(localized: "Microphone permission request timed out. Please allow access in System Settings → Privacy & Security → Microphone, then try again.")) {
                    await speechManager.requestMicPermission()
                }
                guard generation == prepareGeneration else { return }
                guard micOK else {
                    statusMessage = String(localized: "Microphone permission was denied. Please allow it in System Settings → Privacy & Security → Microphone, then try again.")
                    return
                }
                // 3. 启动
                statusMessage = String(localized: "Starting recording…")
                historyStore.startNewRecord()
                do {
                    try speechManager.startRecording()
                    guard generation == prepareGeneration else { return }
                    statusMessage = ""
                    isRecording = true
                } catch {
                    guard generation == prepareGeneration else { return }
                    statusMessage = String(localized: "Failed to start recording. Please check the microphone and try again.")
                }
            }
        }
    }

    /// 跑一步可能卡住的操作。超时只改提示并放开按钮让用户重试，
    /// 不强杀（授权回调丢了的话杀也没用）；用 generation 丢弃过期任务。
    private func runStep(timeoutSeconds: UInt64 = 25, timeoutMessage: String, operation: () async -> Bool) async -> Bool {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            if !Task.isCancelled {
                statusMessage = timeoutMessage
                isPreparing = false
            }
        }
        let ok = await operation()
        watchdog.cancel()
        return ok
    }
    
    private func toggleOverlay() {
        if subtitleWindowController?.window?.isVisible == true { subtitleWindowController?.hideWindow() }
        else { subtitleWindowController?.showWindow() }
    }
}
