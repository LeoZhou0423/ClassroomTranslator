import CoreML
import Foundation

/// 说话人嵌入模型（task-4 Plan A：fbank 前端已内嵌的波形输入 CoreML）。
/// 输入 waveform [1,64000]（16kHz 零填充）+ numSamples [1,1]（有效采样数），
/// 输出 embedding [1,192]。
/// init 返回 nil（包缺失 / 加载失败）时整个功能降级为手动标注 ——
/// 录音与翻译路径不经过这里，绝不受影响（Lead 约束）。
final class SpeakerEmbeddingModel: @unchecked Sendable {
    static let resourceName = "SpeakerCAMWaveZHEng"
    static let outputFeatureName = "embedding"

    private let model: MLModel
    private let inputNames: (waveform: String, numSamples: String)
    private let lock = NSLock()
    private let capacity = SpeakerWindowPolicy.maximumWindowSamples

    init?(bundle: Bundle = .module) {
        let modelURL = bundle.url(
            forResource: Self.resourceName,
            withExtension: "mlpackage"
        ) ?? bundle.url(
            forResource: Self.resourceName,
            withExtension: "mlpackage",
            subdirectory: "Resources"
        )
        guard let modelURL else {
            StartupLog.mark("speaker.model-missing")
            return nil
        }

        let configuration = MLModelConfiguration()
        // 与 AccentClassifier 一致：CPU 上跑，避免 ANE 的不确定调度。
        configuration.computeUnits = .cpuOnly
        guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration) else {
            StartupLog.mark("speaker.model-load-failed")
            return nil
        }
        self.model = model

        let inputs = model.modelDescription.inputDescriptionsByName
        guard inputs["waveform"]?.multiArrayConstraint != nil,
              inputs["numSamples"]?.multiArrayConstraint != nil else {
            StartupLog.mark("speaker.model-inputs-unexpected")
            return nil
        }
        self.inputNames = ("waveform", "numSamples")
        StartupLog.mark("speaker.model-ready")
    }

    /// 推理一个取窗（16kHz mono，1...64000 采样）。任何失败返回 nil，
    /// 调用方按"继承上一标签"降级。
    func embed(window: [Float]) -> [Float]? {
        guard !window.isEmpty, window.count <= capacity else { return nil }

        guard let waveform = try? MLMultiArray(
            shape: [1, NSNumber(value: capacity)],
            dataType: .float32
        ) else { return nil }
        let count = window.count
        for index in 0..<capacity {
            waveform[index] = NSNumber(value: index < count ? window[index] : 0)
        }
        guard let numSamples = try? MLMultiArray(shape: [1, 1], dataType: .float32) else { return nil }
        numSamples[0] = NSNumber(value: Float(count))

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
            inputNames.waveform: waveform,
            inputNames.numSamples: numSamples,
        ]) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard let prediction = try? model.prediction(from: provider),
              let embedding = prediction.featureValue(for: Self.outputFeatureName)?.multiArrayValue,
              embedding.count == 192 else {
            return nil
        }
        var result = [Float](repeating: 0, count: 192)
        for index in 0..<192 {
            result[index] = embedding[index].floatValue
        }
        guard result.contains(where: { $0.isFinite }) else { return nil }
        return result
    }
}
