import Foundation
import AVFoundation

/// 说话人识别取窗策略（task-4，纯逻辑可单测）。
/// 句级时间戳在 onSegmentRecognized 回调里拿不到，所以把句尾近似为
/// "final 落地时刻 − 0.2s 尾迟滞"，句首近似为上一个窗口末端。
/// 注意：报告 §4.2 的"跨度 >4s 取头窗 0–4s"假定已知句首；我们的窗口
/// 末端就是句尾，刚说完的语音在**尾部**，所以取尾窗（语义等价的取窗规则，
/// Mac 验证清单里有对应回归项）。
enum SpeakerWindowPolicy {
    static let sampleRate = 16_000
    static let maximumWindowSamples = 4 * sampleRate
    static let minimumWindowSamples = 9_600          // 0.6s @16k
    static let tailLagSamples = 3_200                // 0.2s @16k
    /// 静音门限 ≈ −45 dBFS：低于此 RMS 视为无语音，继承上一标签。
    static let silenceRMS: Float = 0.0056

    enum Decision: Equatable {
        /// 数据不足 / 窗口太短 / 有效样本过少 → 不推理，段落保持既有标签。
        case inherit
        case window(start: Int, end: Int)
    }

    /// - Parameters:
    ///   - spanStart: 上一窗口末端（绝对采样号）；首句传可用数据起点。
    ///   - spanEnd: 当前 ring 末端绝对采样号。
    ///   - availableStart: ring 中仍可读的最早绝对号（防逐出）。
    static func decision(spanStart: Int, spanEnd: Int, availableStart: Int) -> Decision {
        let end = max(0, spanEnd - tailLagSamples)
        let start = max(max(0, spanStart), availableStart)
        guard end > start else { return .inherit }
        guard end - start >= minimumWindowSamples else { return .inherit }
        // 跨度 >4s：只取紧贴句尾的 4s 尾窗。
        let windowStart = max(start, end - maximumWindowSamples)
        return .window(start: windowStart, end: end)
    }

    static func rms(_ window: [Float]) -> Float {
        guard !window.isEmpty else { return 0 }
        var sum: Float = 0
        for s in window { sum += s * s }
        return sqrt(sum / Float(window.count))
    }

    /// 窗口有效时长（秒），供聚类/标签的时长统计使用。
    static func durationSeconds(_ start: Int, _ end: Int) -> Double {
        Double(max(0, end - start)) / Double(sampleRate)
    }
}
