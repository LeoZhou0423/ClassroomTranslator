import CoreML
import Foundation
import AVFoundation

final class AccentClassifier: @unchecked Sendable {
    struct Result: Sendable {
        let accent: String
        let confidence: Float
        let localeIdentifier: String
    }

    static let defaultLocale = "en-GB"
    static let confidenceThreshold: Float = 0.25

    let labels: [String]
    let sampleRate: Int
    let numSamples: Int
    let inputSeconds: Double

    private let model: MLModel
    private let inputName: String
    private let inputShape: [NSNumber]
    private let outputName: String
    private let lock = NSLock()

    static let accentToLocale: [String: String] = [
        "england": "en-GB",
        "scotland": "en-GB",
        "wales": "en-GB",
        "us": "en-US",
        "canada": "en-CA",
        "australia": "en-AU",
        "indian": "en-IN",
        "ireland": "en-IE",
        "african": "en-ZA",
        "southatlandtic": "en-ZA",
        "malaysia": "en-GB",
        "singapore": "en-GB",
        "hongkong": "en-GB",
        "bermuda": "en-US",
        "philippines": "en-US",
        "newzealand": "en-NZ",
    ]

    static func locale(forAccent accent: String) -> String {
        accentToLocale[accent] ?? defaultLocale
    }

    init?(bundle: Bundle = .main) {
        let modelURL = bundle.url(
            forResource: "AccentECAPA",
            withExtension: "mlpackage"
        ) ?? bundle.url(
            forResource: "AccentECAPA",
            withExtension: "mlpackage",
            subdirectory: "Resources"
        )
        guard let modelURL else {
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            return nil
        }
        self.model = model

        let modelDescription = model.modelDescription
        guard let inputFeature = modelDescription.inputDescriptionsByName.values.first else {
            return nil
        }
        self.inputName = inputFeature.name
        self.inputShape = inputFeature.multiArrayConstraint.shape
        guard let outputFeature = modelDescription.outputDescriptionsByName.values.first else {
            return nil
        }
        self.outputName = outputFeature.name

        let meta = model.modelDescription.metadata.userDefined
        let bundledLabelsURL = bundle.url(forResource: "labels", withExtension: "json")
            ?? bundle.url(forResource: "labels", withExtension: "json", subdirectory: "Resources")
        if let orderJSON = meta["labels"],
           let data = orderJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            self.labels = arr
        } else if let labelsURL = bundledLabelsURL,
                  let data = try? Data(contentsOf: labelsURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["order"] as? [String] {
            self.labels = arr
        } else {
            self.labels = [
                "england", "us", "canada", "australia", "indian", "scotland",
                "ireland", "african", "malaysia", "newzealand", "southatlandtic",
                "bermuda", "philippines", "hongkong", "wales", "singapore",
            ]
        }

        self.sampleRate = Int(meta["sampleRate"] ?? "") ?? 16000
        if let seconds = Double(meta["inputSeconds"] ?? "") {
            self.inputSeconds = seconds
        } else {
            self.inputSeconds = 3.0
        }
        if let n = Int(meta["numSamples"] ?? "") {
            self.numSamples = n
        } else {
            self.numSamples = Int((Double(sampleRate) * inputSeconds).rounded())
        }
    }

    func classify(monoSamples: [Float], sampleRate inputSR: Int = 16000) -> Result? {
        guard !monoSamples.isEmpty else { return nil }

        var samples = monoSamples
        if inputSR != sampleRate {
            samples = Self.resample(samples, from: inputSR, to: sampleRate)
        }
        if samples.count > numSamples {
            samples = Array(samples.prefix(numSamples))
        } else if samples.count < numSamples {
            samples.append(contentsOf: repeatElement(Float(0), count: numSamples - samples.count))
        }

        let shape = inputShape.isEmpty ? [NSNumber(value: numSamples)] : inputShape
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else {
            return nil
        }
        samples.withUnsafeBufferPointer { buf in
            let capacity = array.count
            let dst = array.dataMemory.bindMemory(to: Float.self, capacity: capacity)
            let count = min(capacity, min(numSamples, buf.count))
            if let base = buf.baseAddress {
                dst.update(from: base, count: count)
            }
            if count < capacity {
                for i in count..<capacity { dst[i] = 0 }
            }
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: array]) else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        guard let prediction = try? model.prediction(from: provider),
              let logits = prediction.featureValue(for: outputName)?.multiArrayValue else {
            return nil
        }

        let n = labels.count
        guard logits.count >= n else { return nil }

        var maxLogit = -Float.greatestFiniteMagnitude
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = logits[i].floatValue
            raw[i] = v
            if v > maxLogit { maxLogit = v }
        }
        var sum: Float = 0
        var probs = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let e = exp(raw[i] - maxLogit)
            probs[i] = e
            sum += e
        }
        guard sum > 0 else { return nil }
        var best = 0
        var bestP: Float = -1
        var secondP: Float = 0
        for i in 0..<n {
            probs[i] /= sum
            if probs[i] > bestP {
                secondP = max(secondP, bestP)
                bestP = probs[i]
                best = i
            } else if probs[i] > secondP {
                secondP = probs[i]
            }
        }
        let accent = labels[best]
        let margin = max(0, bestP - secondP)
        let confidence = min(1, margin / 0.06)
        return Result(
            accent: accent,
            confidence: confidence,
            localeIdentifier: Self.locale(forAccent: accent)
        )
    }

    static func resample(_ input: [Float], from srcRate: Int, to dstRate: Int) -> [Float] {
        guard srcRate > 0, dstRate > 0, srcRate != dstRate, !input.isEmpty else { return input }
        let ratio = Double(srcRate) / Double(dstRate)
        let outCount = max(1, Int(Double(input.count) / ratio))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let idx = Int(srcPos)
            if idx + 1 < input.count {
                let frac = Float(srcPos) - Float(idx)
                out[i] = input[idx] * (1 - frac) + input[idx + 1] * frac
            } else if idx < input.count {
                out[i] = input[idx]
            }
        }
        return out
    }

    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channelCount)
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                mono[frameIndex] += channel[frameIndex] * scale
            }
        }
        return mono
    }
}
