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
    private let waveform: MLMultiArray
    private let numSamples: MLMultiArray
    private var previousSampleCount = 0

    init?(bundle: Bundle = .lingoResources) {
        let configuration = MLModelConfiguration()
        // 与 AccentClassifier 一致：CPU 上跑，避免 ANE 的不确定调度。
        configuration.computeUnits = .cpuOnly
        guard let model = BundledMLModelLoader.load(
            resource: Self.resourceName,
            bundle: bundle,
            configuration: configuration
        ) else {
            StartupLog.mark("speaker.model-load-failed")
            return nil
        }
        self.model = model

        guard let waveform = try? MLMultiArray(
            shape: [1, NSNumber(value: capacity)],
            dataType: .float32
        ), let numSamples = try? MLMultiArray(shape: [1, 1], dataType: .float32) else {
            StartupLog.mark("speaker.model-buffer-allocation-failed")
            return nil
        }
        self.waveform = waveform
        self.numSamples = numSamples

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

        lock.lock()
        defer { lock.unlock() }
        let count = window.count
        for index in 0..<count { waveform[index] = NSNumber(value: window[index]) }
        // 上一次窗口更长时，只清掉残留的尾部；首次使用时数组本身已为零。
        if previousSampleCount > count {
            for index in count..<previousSampleCount { waveform[index] = 0 }
        }
        previousSampleCount = count
        numSamples[0] = NSNumber(value: Float(count))

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
            inputNames.waveform: waveform,
            inputNames.numSamples: numSamples,
        ]) else { return nil }

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
