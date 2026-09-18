import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("fontSize") private var fontSize: Double = 16
    @AppStorage("overlayOpacity") private var overlayOpacity: Double = 0.85
    @AppStorage("recognitionLanguage") private var recognitionLanguage: String = "en-GB"
    @AppStorage("translationTarget") private var translationTarget: String = "zh-Hans"
    @AppStorage("autoScroll") private var autoScroll: Bool = true
    
    /// English accent options - comprehensive list
    private let englishAccents: [(name: String, code: String)] = [
        // 英语母语国家
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
                    Text("Select the accent that matches your teacher's English")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("English Accent", selection: $recognitionLanguage) {
                        ForEach(englishAccents, id: \.code) { accent in
                            Text(accent.name).tag(accent.code)
                        }
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
    }
}
