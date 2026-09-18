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
    /// 全程带 20s 超时：系统下载框卡住也不让“检查中”永远转。
    func refreshModelStatus() async {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            guard let session = sessionStorage as? TranslationSession else {
                modelReady = false
                return
            }
            modelReady = await prepareSucceeds(session)
            return
        }
        #endif
        modelReady = false
    }

    /// 主动触发模型下载（只下模型不翻译），返回下载后是否就绪。
    /// 用户取消或失败时返回 false。同样带 20s 超时。
    func downloadModels() async -> Bool {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            guard let session = sessionStorage as? TranslationSession else { return false }
            let ready = await prepareSucceeds(session)
            modelReady = ready
            return ready
        }
        #endif
        return false
    }

    #if canImport(Translation)
    /// 调 prepareTranslation() 判断模型是否就绪：
    /// 已装则立即成功；未装则弹系统下载框（含进度条）；
    /// 用户取消/失败/20s 无响应都视为未就绪，避免永远等待。
    private func prepareSucceeds(_ session: TranslationSession) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var didResume = false
            func finish(_ value: Bool) {
                lock.lock()
                if !didResume { didResume = true; lock.unlock(); continuation.resume(returning: value) }
                else { lock.unlock() }
            }
            let worker = Task {
                do {
                    try await session.prepareTranslation()
                    finish(true)
                } catch {
                    finish(false)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                worker.cancel()
                finish(false)
            }
        }
    }
    #endif
}
