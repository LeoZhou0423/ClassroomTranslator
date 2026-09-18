import Foundation
#if canImport(Translation)
import Translation
#endif

@MainActor
@Observable
final class TranslationManager {
    var translatedText = ""
    var isTranslating = false

    /// 由 SwiftUI `.translationTask` 注入的 TranslationSession。
    /// TranslationSession 没有公开初始化器，只能由系统提供；
    /// 用 Any 存放以保证 macOS 14 SDK 下也能编译。
    private var sessionStorage: Any?

    #if canImport(Translation)
    @available(macOS 15, *)
    func attach(session: TranslationSession) {
        sessionStorage = session
    }
    #endif

    func translate(_ text: String) async -> String {
        guard !text.isEmpty else { return "" }

        isTranslating = true
        defer { isTranslating = false }

        #if canImport(Translation)
        if #available(macOS 15, *) {
            if let session = sessionStorage as? TranslationSession {
                do {
                    let response = try await session.translate(text)
                    return response.targetText
                } catch {
                    print("Translation failed: \(error)")
                    return text
                }
            }
        }
        #endif

        // 无可用 session（macOS 14 / 模型未就绪）：原样返回
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
