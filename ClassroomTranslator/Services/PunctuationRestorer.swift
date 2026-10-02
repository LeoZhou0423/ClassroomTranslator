import Foundation
import SherpaOnnx

/// 在 ASR 终稿进入切句/翻译管线之前恢复标点。
///
/// 背景（2026-10 课堂实测，PHIL 176）：流式识别产出的是无句末标点的碎句，
/// `StableSentenceUnits` 只能按 `.!?` 切句，于是翻译单元变成半截话长串，
/// 逐句硬翻质量极差。本类把终稿喂给 sherpa-onnx 的 OfflinePunctuation
/// （zh-en CT-Transformer，实测单句 3–11 ms），再做
/// `PunctuationTextRepair`（全角→半角 + 误切边界降级），让切句器拿到
/// 带标点的干净句子。
///
/// 模型缺席时 `restore` 原样返回输入 —— 行为与未引入本类完全一致，
/// 因此 CI 与未下载模型的用户都不受影响。
final class PunctuationRestorer: @unchecked Sendable {
    static let shared = PunctuationRestorer()

    private let queue = DispatchQueue(label: "lingoclass.punctuation.restore")
    private var wrapper: SherpaOnnxOfflinePunctuationWrapper?
    private var loadFailed = false
    /// 单次送模型的长度上限：CT-Transformer 是 BERT 系，超长序列既慢又
    /// 会截断，按词边界切块处理。
    private static let chunkCharacterLimit = 240

    var isAvailable: Bool {
        PunctuationModelStore.modelFilesPresent() && !loadFailed
    }

    /// 恢复标点并做文本修复。不可用时原样返回。
    func restore(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, trimmed.count > 12 else { return text }
        return queue.sync {
            guard let model = ensureWrapper() else { return text }
            let punctuated = Self.chunks(of: trimmed)
                .map { model.addPunct(text: $0) }
                .joined(separator: " ")
            return PunctuationTextRepair.repaired(punctuated)
        }
    }

    private func ensureWrapper() -> SherpaOnnxOfflinePunctuationWrapper? {
        if let wrapper { return wrapper }
        guard !loadFailed, PunctuationModelStore.modelFilesPresent() else { return nil }
        var config = sherpaOnnxOfflinePunctuationConfig(
            model: sherpaOnnxOfflinePunctuationModelConfig(
                ctTransformer: PunctuationModelStore.modelFileURL.path,
                numThreads: 2,
                debug: 0,
                provider: "cpu"))
        let created = SherpaOnnxOfflinePunctuationWrapper(config: &config)
        guard created.ptr != nil else {
            loadFailed = true
            StartupLog.mark("punct.wrapper-create-failed")
            return nil
        }
        wrapper = created
        StartupLog.mark("punct.ready")
        return created
    }

    /// 按词边界切块，避免单块超过模型的序列上限。
    private static func chunks(of text: String, limit: Int = chunkCharacterLimit) -> [String] {
        guard text.count > limit else { return [text] }
        var result: [String] = []
        var current: [String] = []
        var length = 0
        for word in text.split(separator: " ") {
            if length + word.count + 1 > limit, !current.isEmpty {
                result.append(current.joined(separator: " "))
                current = []
                length = 0
            }
            current.append(String(word))
            length += word.count + 1
        }
        if !current.isEmpty { result.append(current.joined(separator: " ")) }
        return result
    }
}
