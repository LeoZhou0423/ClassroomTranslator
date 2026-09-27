import Foundation
import AVFoundation

final class AccentAudioTee: @unchecked Sendable {
    let targetSeconds: Double
    private let sampleRate: Double
    private let lock = NSLock()
    private var samples: [Float] = []
    private var emitted = false
    private var enabled = true
    private var readyHandler: (@Sendable ([Float], Int) -> Void)?
    /// The VM bridge is quieter than a physical Mac (speech is often ~0.002 RMS).
    static let minimumSpeechRMS: Float = 0.0015

    var onReady: (@Sendable ([Float], Int) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return readyHandler
        }
        set {
            lock.lock()
            readyHandler = newValue
            lock.unlock()
        }
    }

    init(targetSeconds: Double = 2.5, sampleRate: Double = 16_000) {
        self.targetSeconds = targetSeconds
        self.sampleRate = sampleRate
    }

    var isEmitted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return emitted
    }

    func reset() {
        lock.lock()
        samples = []
        emitted = false
        enabled = true
        lock.unlock()
    }

    func disable() {
        lock.lock()
        enabled = false
        samples = []
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard enabled, !emitted else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let mono = AccentClassifier.monoSamples(from: buffer) else { return }
        let srcRate = buffer.format.sampleRate
        let converted: [Float]
        if abs(srcRate - sampleRate) < 1 {
            converted = mono
        } else {
            converted = AccentClassifier.resample(mono, from: Int(srcRate.rounded()), to: Int(sampleRate))
        }
        guard Self.containsSpeech(converted) else { return }

        lock.lock()
        guard enabled, !emitted else {
            lock.unlock()
            return
        }
        samples.append(contentsOf: converted)
        let need = Int(targetSeconds * sampleRate)
        if samples.count >= need {
            let payload = Array(samples.prefix(max(need, Int(targetSeconds * sampleRate))))
            samples = []
            emitted = true
            enabled = false
            let callback = readyHandler
            lock.unlock()
            let rate = Int(sampleRate)
            callback?(payload, rate)
            return
        }
        lock.unlock()
    }

    static func containsSpeech(_ values: [Float]) -> Bool {
        rms(values) >= minimumSpeechRMS
    }

    private static func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sum: Float = 0
        for value in values { sum += value * value }
        return sqrt(sum / Float(values.count))
    }
}
