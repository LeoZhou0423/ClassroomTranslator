import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// 主窗口传入；App 级 Settings 场景下为 nil，此时隐藏模型状态行
    var translationManager: TranslationManager?
    var showsDoneButton = true
    /// 下载按钮的即时反馈文案，避免“点了没反应”
    @State private var modelStatusMessage = ""
    
    @AppStorage("fontSize") private var fontSize: Double = 16
    @AppStorage("overlayOpacity") private var overlayOpacity: Double = 0.85
    @AppStorage("recognitionLanguage") private var recognitionLanguage: String = "auto"
    @AppStorage("translationTarget") private var translationTarget: String = "zh-Hans"
    @AppStorage("autoScroll") private var autoScroll: Bool = true
    @AppStorage("subtitleMaxWords") private var subtitleMaxWords: Int = 12
    @AppStorage("showSubtitleOriginal") private var showSubtitleOriginal: Bool = true
    /// VIS-05：悬浮窗点击穿透，默认关闭（关 = 不穿透 = 仍可拖动）。
    @AppStorage("overlayClickThrough") private var overlayClickThrough: Bool = false
    @AppStorage("appLanguage") private var appLanguage: String = "zh-Hans"
    /// task-4：说话人识别设置。开关默认开启（Lead 约定）；
    /// 模型缺失时即使开着也整体降级为手动标注。
    @AppStorage("speakerDetectionEnabled") private var speakerDetectionEnabled: Bool = true
    @AppStorage("speakerMaxSpeakers") private var speakerMaxSpeakers: Int = 4
    @AppStorage("speakerThreshold") private var speakerThreshold: Double = 0.5
    /// task-6：语音引擎选择。字面量 key 与 SpeechEngineKind.defaultsKey 一致，
    /// 由单测 testDefaultsKeyIsSpeechEngine 锁定；默认 apple（Step 1 暂只暴露 Apple）。
    @AppStorage("speechEngine") private var speechEngineChoice: String = "apple"
    
    @AppStorage("translationBackend") private var translationBackend: String = "apple"
    @State private var localModelBusy = false
    @State private var localModelStatus = ""
    @State private var isDownloadingAll = false
    @State private var downloadProgress = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                
                Spacer()
                
                if showsDoneButton {
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            
            Divider()
            
            Form {
                Section("App Language") {
                    Picker("Language", selection: $appLanguage) {
                        Text("中文").tag("zh-Hans")
                        Text("English").tag("en")
                        Text("Follow System").tag("system")
                    }
                    .onChange(of: appLanguage) { _, _ in
                        Task { @MainActor in
                            ClassroomTranslatorApp.applyAppLanguage()
                        }
                    }
                    Text("Restart the app to apply the language change.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Subtitle Display") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(fontSize))pt")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $fontSize, in: 12...36, step: 2)
                    
                    HStack {
                        Text("Overlay Opacity")
                        Spacer()
                        Text("\(Int(overlayOpacity * 100))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $overlayOpacity, in: 0.3...1.0, step: 0.05)

                    Stepper("Short subtitle length: \(subtitleMaxWords) words", value: $subtitleMaxWords, in: 6...18)

                    Toggle("Show original text", isOn: $showSubtitleOriginal)
                    
                    Toggle("Auto Scroll", isOn: $autoScroll)

                    Toggle("Click Through Overlay", isOn: $overlayClickThrough)
                    Text("When on, clicks pass through the overlay and dragging is disabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // task-4：说话人识别（老师/学生自动标注）。默认开启；
                // 模型缺失时整体降级为手动标注，录音与翻译不受影响。
                Section("Speaker Labels") {
                    Toggle("Automatically tag speakers", isOn: $speakerDetectionEnabled)
                    Text("Teacher and student labels are assigned on-device. When the model is unavailable, tagging falls back to manual editing in the session detail.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Stepper("Maximum speakers: \(speakerMaxSpeakers)", value: $speakerMaxSpeakers, in: 2...4)
                        .disabled(!speakerDetectionEnabled)

                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(String(format: "%.2f", speakerThreshold))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $speakerThreshold, in: 0.45...0.75, step: 0.05)
                        .disabled(!speakerDetectionEnabled)
                    Text("Higher requires voices to be more similar before they are grouped as the same speaker.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // task-6 Step 2：语音引擎选择（默认 apple）。sherpa 仅在模型
                // 资源齐全时列出；选择在下次进入录音页时生效。
                Section("Speech Engine") {
                    Picker("Engine", selection: $speechEngineChoice) {
                        Text("Apple SpeechAnalyzer").tag(SpeechEngineKind.apple.rawValue)
                        if SherpaSpeechEngine.modelsPresent() {
                            Text("Sherpa-onnx · English streaming").tag(SpeechEngineKind.sherpa.rawValue)
                        }
                        Text("Whisper · better accuracy").tag(SpeechEngineKind.whisper.rawValue)
                    }
                    Text("Applies the next time the recording page opens.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // Lead Step 2 令第 5 条：首字延迟如实标注，避免被当成 bug。
                    if speechEngineChoice == SpeechEngineKind.sherpa.rawValue {
                        Text("Sherpa-onnx: first text appears after about 1–1.3 seconds of speech; this is model context, not a fault.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if WhisperModelStore.shared.usesOnnxCompatibilityBackend {
                        Text("Whisper uses ONNX on CPU on both physical Macs and virtual machines.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if speechEngineChoice == SpeechEngineKind.whisper.rawValue {
                        Text("Whisper: higher accuracy on classroom and TTS audio; first run downloads the model. Text updates every few seconds (batch decoding).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        whisperTierPicker
                        whisperDownloadSection
                    }
                }

                Section("Teacher Language / Model") {
                    Text("Auto English starts with UK English, then detects the teacher’s accent and switches if needed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Language", selection: $recognitionLanguage) {
                        ForEach(LanguageOptions.sources) { language in
                            Text(LocalizedStringKey(language.name)).tag(language.code)
                        }
                    }
                    
                    // UX-05：原来只有 auto 才给预下载入口，选了固定口音（en-US 等）的用户
                    // 第一次点 Start 只能干等下载。这里放开到所有英语口音；
                    // 该入口只下载英语模型，所以纯非英语选择下不出现在这里（由自动检测兜底）。
                    if recognitionLanguage == "auto" || recognitionLanguage.hasPrefix("en") {
                        Button(action: downloadAllSpeechModels) {
                            HStack {
                                if isDownloadingAll { ProgressView().controlSize(.small) }
                                Text(isDownloadingAll ? downloadProgress : String(localized: "Download All English Models"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDownloadingAll)
                    }
                }
                
                Section("Translation") {
                    Picker("Target Language", selection: $translationTarget) {
                        ForEach(LanguageOptions.targets) { language in
                            Text(LocalizedStringKey(language.name)).tag(language.code)
                        }
                    }
                    
                    if #available(macOS 15, *) {
                        if let manager = translationManager {
                            HStack {
                                Text("Model Status")
                                Spacer()
                                Text(modelStatusText(manager.modelReady))
                                    .foregroundColor(.secondary)
                            }

                            Button("Download Language Models") {
                                startModelDownload(manager)
                            }
                            .buttonStyle(.bordered)
                            .disabled(manager.modelReady == true)

                            if !manager.hasSession {
                                Button("Download Language Packs in System Settings…") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.localization") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.link)
                            }

                            if !modelStatusMessage.isEmpty {
                                Text(modelStatusMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("Models download in the background. You can also pre-download them in the Translate app.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Realtime system translation requires macOS 15 or later. Speech transcripts can still be recorded.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                
                Section("翻译引擎") {
                    Picker("翻译模型", selection: $translationBackend) {
                        Text("Apple 系统翻译").tag("apple")
                        Text("TranslateGemma 4B · 本地").tag("translateGemma")
                    }
                    Text("切换后重新进入录音页生效。英文字幕不等待翻译完成。")
                        .font(.caption).foregroundColor(.secondary)
                    if translationBackend == "translateGemma" {
                        Text("先安装并启动 Ollama，再下载翻译模型（约 3.3 GB）。模型在本机运行，会与 Whisper 共用内存和计算资源。")
                            .font(.caption).foregroundColor(.secondary)
                        Link("安装 Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
                        HStack {
                            Button("检查本地模型") { checkLocalTranslationModel(download: false) }
                            Button("下载翻译模型") { checkLocalTranslationModel(download: true) }
                        }.disabled(localModelBusy)
                        if !localModelStatus.isEmpty {
                            Text(localModelStatus).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Speech Engine")
                        Spacer()
                        // task-6 Step 2：动态显示实际会启用的引擎（模型缺失或
                        // 创建失败熔断时如实回落为 Apple）。verbatim：专有名词
                        // 不走本地化查找。
                        Text(verbatim: resolvedEngineDisplayName)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Supported Accents")
                        Spacer()
                        Text("\(LanguageOptions.sources.count) languages/models")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 450, minHeight: 550)
        .task {
            recognitionLanguage = LanguageOptions.supportedSource(recognitionLanguage)
            await translationManager?.refreshModelStatus()
        }
    }
    
    private func checkLocalTranslationModel(download: Bool) {
        localModelBusy = true
        localModelStatus = download ? "正在下载 TranslateGemma 4B，请保持 Ollama 运行…" : "正在检查…"
        Task { @MainActor in
            defer { localModelBusy = false }
            do {
                let client = LocalTranslationClient()
                if download { try await client.downloadModel() }
                let installed = try await client.modelInstalled()
                localModelStatus = installed ? "模型已就绪，可重新进入录音页测试。" : "Ollama 已连接，翻译模型尚未下载。"
            } catch { localModelStatus = error.localizedDescription }
        }
    }

    /// About 区动态引擎行。刻意用 isAvailable + fallback 而非 resolved：
    /// 渲染路径不应反复触发 StartupLog 记日志。
    private var resolvedEngineDisplayName: String {
        let kind = SpeechEngineKind()
        let effective = kind.isAvailable ? kind : SpeechEngineKind.fallback
        switch effective {
        case .apple: return "Apple SpeechAnalyzer"
        case .sherpa: return "Sherpa-onnx · English streaming"
        case .whisper: return "Whisper · better accuracy"
        }
    }

    private func modelStatusText(_ ready: Bool?) -> String {
        if ready == true { return String(localized: "Ready") }
        if ready == false { return String(localized: "Not downloaded") }
        return String(localized: "Checking…")
    }
    
    private func downloadAllSpeechModels() {
        isDownloadingAll = true
        // 赋给 String 状态再喂给 Text() 会绕过 LocalizedStringKey 查表，必须显式本地化。
        downloadProgress = String(localized: "Preparing…")
        Task {
            // 先请求权限
            let sm = SpeechManager()
            _ = await sm.requestSpeechPermission()
            _ = await sm.requestMicPermission()

            downloadProgress = String(localized: "Downloading models…")
            let result = await sm.downloadAllEnglishModels()
            downloadProgress = String(
                format: String(localized: "%lld/%lld models ready."),
                result.ready,
                result.total
            )
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            isDownloadingAll = false
            downloadProgress = ""
        }
    }

    /// Whisper 档位：按内存/VM 推荐默认值，用户可改。
    @ViewBuilder
    private var whisperTierPicker: some View {
        let store = WhisperModelStore.shared
        let recommended = WhisperModelTier.recommended()
            VStack(alignment: .leading, spacing: 6) {
                Picker("Model size", selection: Binding(
                    get: { store.tier },
                    set: { store.selectTier($0) }
                )) {
                    ForEach(WhisperModelTier.allCases) { tier in
                        Text(tier.title).tag(tier)
                    }
                }
                Text(store.tier.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if store.tier != recommended {
                    Text(String(
                        format: String(localized: "Recommended for this Mac: %@"),
                        recommended.title
                    ))
                    .font(.caption2)
                    .foregroundColor(.orange)
                } else {
                    Text(String(localized: "Recommended for this Mac"))
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
    }

    /// Whisper 大模型：必须预下载并显示进度，禁止只在点开始时默默下。
    private var whisperDownloadSection: some View {
        let store = WhisperModelStore.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if store.isDownloading {
                    ProgressView(value: store.fraction)
                        .frame(maxWidth: 180)
                }
                Text(store.message.isEmpty
                     ? (store.isReady ? String(localized: "Whisper model ready.")
                                      : String(localized: "Whisper model not downloaded"))
                     : store.message)
                    .font(.caption)
                    .foregroundColor(store.lastError == nil ? .secondary : .red)
            }
            Button(store.isReady ? String(localized: "Re-download Whisper Model")
                                 : String(localized: "Download Whisper Model")) {
                Task { await store.download() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isDownloading)
            Text("Whisper weights are large. Download here first, then start recording.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func startModelDownload(_ manager: TranslationManager) {
        // 会话缺失时：先失效重来一份，等系统重新下发，再下载
        guard manager.hasSession else {
            modelStatusMessage = String(localized: "Getting the translation session…")
            manager.requestSessionRefresh()
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard manager.hasSession else {
                    modelStatusMessage = String(localized: "Still no translation session. Please download the language packs in System Settings or the Translate app.")
                    return
                }
                await doDownload(manager)
            }
            return
        }
        Task { await doDownload(manager) }
    }

    private func doDownload(_ manager: TranslationManager) async {
        modelStatusMessage = String(localized: "Requesting model download…")
        let ready = await manager.downloadModels()
        if ready {
            modelStatusMessage = String(localized: "Models are ready.")
        } else {
            modelStatusMessage = String(localized: "Model download is unavailable. Please download the translation languages in System Settings or the Translate app.")
        }
    }
}
