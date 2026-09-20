import Foundation

enum LanguageOptions {
    struct Option: Identifiable, Hashable {
        let name: String
        let code: String
        var id: String { code }
    }

    static let sources: [Option] = [
        Option(name: "Auto English (system region)", code: "auto"),
        Option(name: "English (US)", code: "en-US"),
        Option(name: "English (UK)", code: "en-GB"),
        Option(name: "English (Australia)", code: "en-AU"),
        Option(name: "English (New Zealand)", code: "en-NZ"),
        Option(name: "English (Ireland)", code: "en-IE"),
        Option(name: "English (South Africa)", code: "en-ZA"),
        Option(name: "English (Canada)", code: "en-CA"),
        Option(name: "English (India)", code: "en-IN"),
        Option(name: "中文", code: "zh-Hans"),
        Option(name: "日本語", code: "ja-JP"),
        Option(name: "한국어", code: "ko-KR"),
        Option(name: "हिन्दी", code: "hi-IN"),
        Option(name: "العربية", code: "ar-SA"),
        Option(name: "Türkçe", code: "tr-TR"),
        Option(name: "Bahasa Indonesia", code: "id-ID"),
    ]

    static let targets: [Option] = [
        Option(name: "中文（简体）", code: "zh-Hans"),
        Option(name: "中文（繁體）", code: "zh-Hant"),
        Option(name: "English", code: "en-GB"),
        Option(name: "日本語", code: "ja-JP"),
        Option(name: "한국어", code: "ko-KR"),
        Option(name: "العربية", code: "ar-SA"),
        Option(name: "Türkçe", code: "tr-TR"),
    ]

    static func name(for code: String) -> String {
        (sources + targets).first(where: { $0.code == code })?.name ?? code
    }

    static func supportedSource(_ code: String) -> String {
        sources.contains(where: { $0.code == code }) ? code : "auto"
    }
}
