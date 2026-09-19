import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// 主窗口传入；App 级 Settings 场景下为 nil，此时隐藏模型状态行
    var translationManager: TranslationManager?
    /// 下载按钮的即时反馈文案，避免“点了没反应”
    @State private var modelStatusMessage = ""
    
    @AppStorage("fontSize") private var fontSize: Double = 16
    @AppStorage("overlayOpacity") private var overlayOpacity: Double = 0.85
    @AppStorage("recognitionLanguage") private var recognitionLanguage: String = "auto"
    @AppStorage("translationTarget") private var translationTarget: String = "zh-Hans"
    @AppStorage("autoScroll") private var autoScroll: Bool = true
    @AppStorage("appLanguage") private var appLanguage: String = "zh-Hans"
    
    @State private var isDownloadingAll = false
    @State private var downloadProgress = ""
    
    /// English accent options
    private let englishAccents: [(name: String, code: String)] = [
        ("Auto (detect while recording)", "auto"),
        ("🇺🇸 English (US) - American", "en-US"),
        ("🇬🇧 English (UK) - British", "en-GB"),
        ("🇦🇺 English (AU) - Australian", "en-AU"),
        ("🇳🇿 English (NZ) - New Zealand", "en-NZ"),
        ("🇮🇪 English (IE) - Irish", "en-IE"),
        ("🇿🇦 English (ZA) - South African", "en-ZA"),
        ("🇨🇦 English (CA) - Canadian", "en-CA"),
        
        // 亚洲地区英语口音
        ("🇮🇳 English (IN) - Indian", "en-IN"),
        ("🇵🇭 English (PH) - Filipino", "en-PH"),
        ("🇸🇬 English (SG) - Singaporean", "en-SG"),
        ("🇲🇾 English (MY) - Malaysian", "en-MY"),
        
        // 日韩地区
        ("🇯🇵 English (JP) - Japanese", "en-JP"),
        ("🇰🇷 English (KR) - Korean", "en-KR"),
        
        // 中东地区
        ("🇦🇪 English (AE) - UAE", "en-AE"),
        ("🇸🇦 English (SA) - Saudi", "en-SA"),
        ("🇮🇱 English (IL) - Israeli", "en-IL"),
        ("🇹🇷 English (TR) - Turkish", "en-TR"),
        ("🇪🇬 English (EG) - Egyptian", "en-EG"),
        ("🇶🇦 English (QA) - Qatari", "en-QA"),
        ("🇰🇼 English (KW) - Kuwaiti", "en-KW"),
        ("🇧🇭 English (BH) - Bahraini", "en-BH"),
        ("🇴🇲 English (OM) - Omani", "en-OM"),
        ("🇯🇴 English (JO) - Jordanian", "en-JO"),
        ("🇱🇧 English (LB) - Lebanese", "en-LB"),
    ]
    
    /// Other languages
    private let otherLanguages: [(name: String, code: String)] = [
        ("中文 (Mandarin)", "zh-Hans"),
        ("日本語 (Japanese)", "ja-JP"),
        ("한국어 (Korean)", "ko-KR"),
        ("हिन्दी (Hindi)", "hi-IN"),
        ("العربية (Arabic)", "ar-SA"),
        ("Türkçe (Turkish)", "tr-TR"),
        ("Bahasa Indonesia", "id-ID"),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
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
                        ClassroomTranslatorApp.applyAppLanguage()
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
                    
                    Toggle("Auto Scroll", isOn: $autoScroll)
                }
                
                Section("Speech Recognition - Teacher's Accent") {
                    Text("Auto mode tries all English accents while recording")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("English Accent", selection: $recognitionLanguage) {
                        ForEach(englishAccents, id: \.code) { accent in
                            Text(accent.name).tag(accent.code)
                        }
                    }
                    
                    if recognitionLanguage == "auto" {
                        Button(action: downloadAllSpeechModels) {
                            HStack {
                                if isDownloadingAll { ProgressView().controlSize(.small) }
                                Text(isDownloadingAll ? downloadProgress : "Download All English Models")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDownloadingAll)
                    }
                }
                
                Section("Other Languages") {
                    Text("Or select if teacher speaks another language")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Language", selection: $recognitionLanguage) {
                        ForEach(otherLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }
                
                Section("Translation") {
                    Picker("Target Language", selection: $translationTarget) {
                        Text("中文 (Simplified)").tag("zh-Hans")
                        Text("中文 (Traditional)").tag("zh-Hant")
                        Text("日本語").tag("ja-JP")
                        Text("한국어").tag("ko-KR")
                        Text("English").tag("en-GB")
                        Text("العربية").tag("ar-SA")
                        Text("Türkçe").tag("tr-TR")
                    }
                    
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
                        Text("\(englishAccents.count) accents")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 450, minHeight: 550)
        .task {
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
        downloadProgress = "Preparing…"
        Task {
            // 先请求权限
            let sm = SpeechManager()
            _ = await sm.requestSpeechPermission()
            _ = await sm.requestMicPermission()
            
            downloadProgress = "Downloading models…"
            let result = await sm.downloadAllEnglishModels()
            downloadProgress = "\(result.ready)/\(result.total) models ready."
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
