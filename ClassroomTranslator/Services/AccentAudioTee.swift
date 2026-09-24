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
}
