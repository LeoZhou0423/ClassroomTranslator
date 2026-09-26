import Foundation
import AVFoundation

/// 说话人识别取窗用的 16kHz 环形缓冲（task-4）。
/// 结构对齐 AccentAudioTee：麦克风 tap 里 append（设备采样率 → 混单 → 重采样），
/// 绝对采样号从 reset() 起计数，窗口按 [start, end) 绝对区间读取，
/// 容量 30 秒（≥ 重聚类所需的全量窗口跨度，正常句子窗口 ≤4s）。
final class SpeakerAudioRing: @unchecked Sendable {
    let capacitySeconds: Double
    private let sampleRate: Double
    private let lock = NSLock()
    private var samples: [Float]
    private var writeIndex = 0
    private var validCount = 0
    private var appendedTotal = 0
    private var accepting = false

    init(capacitySeconds: Double = 30, sampleRate: Double = 16_000) {
        self.capacitySeconds = capacitySeconds
        self.sampleRate = sampleRate
        samples = [Float](repeating: 0, count: Int(capacitySeconds * sampleRate))
    }

    /// reset 后可写（setSpeakerCapture(true) 路径）。
    var isAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting
    }

    /// 绝对末端（下一个待写样本的绝对号）。
    var endIndex: Int {
        lock.lock(); defer { lock.unlock() }
        return appendedTotal
    }

    /// 仍可读的最早绝对号（逐出边界）。
    var availableStart: Int {
        lock.lock(); defer { lock.unlock() }
        return appendedTotal - validCount
    }

    /// 开启采集并清零绝对基准（每次 startRecording 走这里）。
    func reset() {
        lock.lock()
        writeIndex = 0
        validCount = 0
        appendedTotal = 0
        accepting = true
        lock.unlock()
    }

    func disable() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    /// 与 AccentAudioTee 同路径：mono 混单 + 线性重采样到 16kHz。
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let live = accepting
        lock.unlock()
        guard live else { return }

        guard let mono = AccentClassifier.monoSamples(from: buffer) else { return }
        let srcRate = buffer.format.sampleRate
        let converted: [Float]
        if abs(srcRate - sampleRate) < 1 {
            converted = mono
        } else {
            converted = AccentClassifier.resample(mono, from: Int(srcRate.rounded()), to: Int(sampleRate))
        }
        appendSamples(converted)
    }

    private func appendSamples(_ converted: [Float]) {
        guard !converted.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        let capacity = samples.count
        for sample in converted {
            samples[writeIndex] = sample
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
            if validCount < capacity { validCount += 1 }
        }
        appendedTotal += converted.count
    }

    /// 读取绝对窗口 [start, end)。数据被逐出 / 越界 / 空窗口 → nil。
    /// 调用方保证 end - start ≤ capacity（窗口策略已裁剪到 ≤4s）。
    func window(from start: Int, to end: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard end > start, start >= 0, end <= appendedTotal else { return nil }
        guard start >= appendedTotal - validCount else { return nil }
        let capacity = samples.count
        guard end - start <= capacity else { return nil }
        var out = [Float](repeating: 0, count: end - start)
        // 绝对号 a 的槽位：writeIndex 之后往回数 (appendedTotal - a) 个。
        var slot = (writeIndex - (appendedTotal - start)) % capacity
        if slot < 0 { slot += capacity }
        for i in 0..<out.count {
            out[i] = samples[slot]
            slot += 1
            if slot == capacity { slot = 0 }
        }
        return out
    }
}
