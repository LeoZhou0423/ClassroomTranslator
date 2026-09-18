import Foundation
#if canImport(Translation)
import Translation
#endif

@MainActor
@Observable
final class TranslationManager {
    var translatedText = ""
    var isTranslating = false

    func translate(_ text: String) async -> String {
        guard !text.isEmpty else { return "" }

        isTranslating = true
        defer { isTranslating = false }

        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            do {
                let source = Locale.Language(languageCode: .english)
                let target = Locale.Language(languageCode: .chinese)
                // init(installedSource:target:) 不弹下载框，只用已安装模型；
                // 需要下载模型的场景请走 SwiftUI .translationTask 拿到的 session
                let session = TranslationSession(installedSource: source, target: target)
                let response = try await session.translate(text)
                return response.targetText
            } catch {
                print("Translation failed: \(error)")
                return text
            }
        }
        #endif

        // macOS 14 / 无 Translation 框架时的降级：原样返回，保证编译通过
        return text
    }

    func translateBatch(_ texts: [String]) async -> [String] {
        var results: [String] = []
        for text in texts {
            let translated = await translate(text)
            results.append(translated)
        }
        return results
    }
}
