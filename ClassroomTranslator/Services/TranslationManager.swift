import Foundation
#if canImport(Translation)
import Translation
#endif

@MainActor
@Observable
final class TranslationManager {
    var translatedText = ""
    var isTranslating = false
    /// 翻译模型状态：nil=未检查，true=已就绪，false=未下载
    var modelReady: Bool?

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

    /// 查询翻译模型是否就绪。未就绪时系统会弹出下载授权框（含进度条），
    /// 点同意后在后台继续下载。
    /// 注：本 SDK 的 TranslationSession 没有 isReady，只能用
    /// prepareTranslation 是否直接通过来判断（已安装则静默返回）。
    func refreshModelStatus() async {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            guard let session = sessionStorage as? TranslationSession else {
                modelReady = false
                return
            }
            do {
                try await session.prepareTranslation()
                modelReady = true
            } catch {
                modelReady = false
            }
            return
        }
        #endif
        modelReady = false
    }

    /// 主动触发模型下载（只下模型不翻译），返回下载后是否就绪。
    /// 用户取消或失败时返回 false。
    func downloadModels() async -> Bool {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            guard let session = sessionStorage as? TranslationSession else { return false }
            do {
                try await session.prepareTranslation()
                modelReady = true
                return true
            } catch {
                print("Model download failed or cancelled: \(error)")
                modelReady = false
                return false
            }
        }
        #endif
        return false
    }
}
