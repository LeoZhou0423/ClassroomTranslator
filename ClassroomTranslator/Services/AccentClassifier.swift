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
    // The classifier reports a normalized top-two margin. Values below 0.40
    // were observed to flip the recognizer to a wrong locale on clean speech;
    // retry instead of degrading all subsequent transcription in the session.
    static let confidenceThreshold: Float = 0.40

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
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        guard let model = BundledMLModelLoader.load(
            resource: "AccentECAPA",
            bundle: bundle,
            configuration: config
        ) else {
            return nil
        }
        self.model = model

        let modelDescription = model.modelDescription
        guard let inputFeature = modelDescription.inputDescriptionsByName.values.first else {
            return nil
        }
        self.inputName = inputFeature.name
        self.inputShape = inputFeature.multiArrayConstraint?.shape ?? []
        guard let outputFeature = modelDescription.outputDescriptionsByName.values.first else {
            return nil
        }
        self.outputName = outputFeature.name

        let bundledLabelsURL = bundle.url(forResource: "labels", withExtension: "json")
            ?? bundle.url(forResource: "labels", withExtension: "json", subdirectory: "Resources")
        var resolvedLabels = [
            "england", "us", "canada", "australia", "indian", "scotland",
            "ireland", "african", "malaysia", "newzealand", "southatlandtic",
            "bermuda", "philippines", "hongkong", "wales", "singapore",
        ]
        var resolvedSampleRate = 16_000
        var resolvedInputSeconds = 3.0
        var resolvedNumSamples = 48_000
        if let labelsURL = bundledLabelsURL,
           let data = try? Data(contentsOf: labelsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let order = object["order"] as? [String], !order.isEmpty {
                resolvedLabels = order
            }
            if let sampleRate = (object["sampleRate"] as? NSNumber)?.intValue, sampleRate > 0 {
                resolvedSampleRate = sampleRate
            }
            if let seconds = (object["inputSeconds"] as? NSNumber)?.doubleValue, seconds > 0 {
                resolvedInputSeconds = seconds
                resolvedNumSamples = Int((Double(resolvedSampleRate) * seconds).rounded())
            }
        }

        self.labels = resolvedLabels
        self.sampleRate = resolvedSampleRate
        self.inputSeconds = resolvedInputSeconds
        self.numSamples = resolvedNumSamples
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
        let capacity = array.count
        let count = min(capacity, min(numSamples, samples.count))
        for index in 0..<capacity {
            array[index] = NSNumber(value: index < count ? samples[index] : 0)
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
        let outputCount = max(1, Int(Double(input.count) / ratio))
        var output = [Float](repeating: 0, count: outputCount)
        if ratio > 1 {
            // Average every source interval instead of selecting one point.
            // This cheap low-pass step avoids folding high-frequency energy
            // into the 16 kHz speech band used by accent, speaker and Whisper.
            for outputIndex in 0..<outputCount {
                var position = Double(outputIndex) * ratio
                let end = min(Double(input.count), Double(outputIndex + 1) * ratio)
                var weightedSum: Double = 0
                var totalWeight: Double = 0
                while position < end {
                    let inputIndex = min(Int(position), input.count - 1)
                    let boundary = min(end, Double(inputIndex + 1))
                    let weight = boundary - position
                    weightedSum += Double(input[inputIndex]) * weight
                    totalWeight += weight
                    position = boundary
                }
                if totalWeight > 0 { output[outputIndex] = Float(weightedSum / totalWeight) }
            }
        } else {
            for outputIndex in 0..<outputCount {
                let position = Double(outputIndex) * ratio
                let lower = min(Int(position), input.count - 1)
                let upper = min(lower + 1, input.count - 1)
                let fraction = Float(position - Double(lower))
                output[outputIndex] = input[lower] * (1 - fraction) + input[upper] * fraction
            }
        }
        return output
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
