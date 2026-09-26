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
    @AppStorage("speakerThreshold") private var speakerThreshold: Double = 0.6
    
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
                        Text("Apple SpeechAnalyzer")
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
