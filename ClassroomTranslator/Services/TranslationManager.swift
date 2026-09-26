import Foundation
#if canImport(Translation)
import Translation
#endif

@MainActor
@Observable
final class TranslationManager {
    var translatedText = ""
    var isTranslating = false
    var lastErrorMessage = ""
    /// 翻译模型状态：nil=未检查，true=已就绪，false=未下载
    var modelReady: Bool?
    /// 自增令牌：Settings 点“下载模型”但会话缺失时 +1，
    /// 让 translationTask 重新下发会话
    var sessionRefreshToken = 0

    /// 由 SwiftUI `.translationTask` 注入的 TranslationSession。
    /// TranslationSession 没有公开初始化器，只能由系统提供；
    /// 用 Any 存放以保证 macOS 14 SDK 下也能编译。
    private var sessionStorage: Any?
    private let requestGate = TranslationRequestGate()
    private var sourceLanguageCode = ""
    private var targetLanguageCode = ""

    #if canImport(Translation)
    @available(macOS 15, *)
    func attach(session: TranslationSession, sourceLanguage: String, targetLanguage: String) {
        sessionStorage = session
        sourceLanguageCode = sourceLanguage
        targetLanguageCode = targetLanguage
        modelReady = Self.baseLanguage(sourceLanguage) == Self.baseLanguage(targetLanguage) ? true : nil
    }
    #endif

    /// 是否已拿到系统下发的翻译会话（macOS 14 恒为 false）。
    /// 拿不到会话时，应用内无法触发系统下载框，只能走系统设置/翻译 App。
    var hasSession: Bool {
        if !sourceLanguageCode.isEmpty,
           Self.baseLanguage(sourceLanguageCode) == Self.baseLanguage(targetLanguageCode) { return true }
        #if canImport(Translation)
        if #available(macOS 15, *) {
            return sessionStorage is TranslationSession
        }
        #endif
        return false
    }

    /// 请求重新下发一次翻译会话（会话缺失时用）
    func requestSessionRefresh() {
        sessionRefreshToken += 1
    }

    /// 丢弃当前缓存的会话。
    /// Apple 文档明确说明：attached view 消失、或 source/target 变化之后再使用旧的
    /// TranslationSession 实例，系统会直接 fatalError。
    /// 所以在任何会作废旧会话的动作（config.invalidate / 换语言 / 视图消失）之前先清空，
    /// 让后续 translate 走“无会话”分支返回空串，而不是踩到已失效的会话。
    /// （只影响新发起的调用，进行中的 await 无法被此方法保护。）
    func detachSession() {
        sessionStorage = nil
    }

    nonisolated static func resolveAutoSource(_ source: String) -> String {
        guard source == "auto" || source == "auto-detect" else { return source }
        if let detected = UserDefaults.standard.string(forKey: "detectedRecognitionLanguage"),
           !detected.isEmpty {
            return detected
        }
        return "en-GB"
    }

    func configureLanguagePair(source: String, target: String) {
        sourceLanguageCode = Self.resolveAutoSource(source)
        targetLanguageCode = target
        if Self.baseLanguage(sourceLanguageCode) == Self.baseLanguage(targetLanguageCode) {
            modelReady = true
        }
    }

    func translate(_ text: String) async -> String {
        guard !text.isEmpty else { return "" }
        if Self.baseLanguage(sourceLanguageCode) == Self.baseLanguage(targetLanguageCode),
           !sourceLanguageCode.isEmpty {
            modelReady = true
            return text
        }

        // TranslationSession is stateful. Serializing live and final requests
        // prevents partial hypotheses from racing a completed sentence.
        await requestGate.acquire()
        if Task.isCancelled {
            await requestGate.release()
            return ""
        }
        isTranslating = true
        let result = await performTranslation(text)
        isTranslating = false
        await requestGate.release()
        return result
    }

    private static func baseLanguage(_ identifier: String) -> String {
        identifier.split(separator: "-").first.map(String.init) ?? identifier
    }

    private func performTranslation(_ text: String) async -> String {

        #if canImport(Translation)
        if #available(macOS 15, *) {
            if let session = sessionStorage as? TranslationSession {
                do {
                    if modelReady != true {
                        try await session.prepareTranslation()
                        modelReady = true
                    }
                    let response = try await session.translate(text)
                    lastErrorMessage = ""
                    return response.targetText
                } catch is CancellationError {
                    return ""
                } catch {
                    // A transient session failure must not permanently disable
                    // translation for the rest of the recording. The next call
                    // will prepare the session again.
                    modelReady = nil
                    lastErrorMessage = error.localizedDescription
                    return ""
                }
            }
        }
        #endif

        // No usable session: leave the translation empty instead of presenting
        // the source text as if it were a successful translation.
        lastErrorMessage = String(localized: "Realtime translation requires macOS 15 or later and downloaded language models.")
        return ""
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
        if !sourceLanguageCode.isEmpty,
           Self.baseLanguage(sourceLanguageCode) == Self.baseLanguage(targetLanguageCode) {
            modelReady = true
            return
        }
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
    /// 用户取消或失败时返回 false。带 30s 超时。
    func downloadModels() async -> Bool {
        if !sourceLanguageCode.isEmpty,
           Self.baseLanguage(sourceLanguageCode) == Self.baseLanguage(targetLanguageCode) {
            modelReady = true
            return true
        }
        #if canImport(Translation)
        if #available(macOS 15, *) {
            guard let session = sessionStorage as? TranslationSession else { return false }
            let ready = await prepareSucceeds(session, timeoutSeconds: 30)
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
    @available(macOS 15, *)
    private func prepareSucceeds(_ session: TranslationSession, timeoutSeconds: UInt64 = 20) async -> Bool {
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
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                worker.cancel()
                finish(false)
            }
        }
    }
    #endif
}

private actor TranslationRequestGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
