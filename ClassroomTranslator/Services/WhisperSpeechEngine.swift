import Foundation
import AVFoundation
import SherpaOnnx
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Whisper（WhisperKit / CoreML）语音引擎 —— 课堂嘈杂、TTS、口音下比
/// Apple Dictation / 小 zipformer 更稳的端侧 ASR。
///
/// 约定与 SherpaSpeechEngine 对齐：
///  · 单活跃引擎、start/stop epoch；晚到的 stop 获胜
///  · tap 层并联 AccentAudioTee + SpeakerAudioRing
///  · 模型缺失/加载失败 → 熔断，工厂下次回退 apple
///  · 实时策略：滚动窗 + 静音分句（Whisper 批量解码，非真流式 token）
final class WhisperSpeechEngine: @unchecked Sendable, SpeechEngine {
    static let displayName = "Whisper"
    /// 滚动窗上限（秒）。过长会让 Whisper 反复整窗解码，吃内存且易拖垮 VM。
    static let maxWindowSeconds = 8

    /// 当前档位变体名（设置覆盖优先，否则按硬件推荐）。
    static var modelName: String {
        if let raw = UserDefaults.standard.string(forKey: WhisperModelTier.defaultsKey),
           let tier = WhisperModelTier(rawValue: raw) {
            return tier.variantName
        }
        return WhisperModelTier.recommended().variantName
    }

    private static let availabilityLock = NSLock()
    private static var creationDisabled = false

    /// CoreML-capable Macs use WhisperKit; QEMU/no-Metal environments use the
    /// CPU ONNX compatibility backend. Both are real Whisper decoders.
    static func isUsable() -> Bool {
        return availabilityLock.withLock { !creationDisabled }
    }

    private static func markCreationFailed(_ reason: String) {
        availabilityLock.withLock { creationDisabled = true }
        StartupLog.mark("whisper.creation-failed reason=\(reason)")
    }

    // MARK: - state

    private let queue = DispatchQueue(label: "com.classroomtranslator.whisperAsr")
    private let stateLock = NSLock()

    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false
    private var stopEpoch = 0

    private var recognitionHandler: (@Sendable (String, Bool) -> Void)?

    private let accentTee = AccentAudioTee(targetSeconds: 3.0)
    let speakerRing = SpeakerAudioRing(capacitySeconds: 30)

    /// 16 kHz mono 滚动窗（最多 8s，控制 VM 解码延迟和内存）。
    private var sampleBuffer: [Float] = []
    private var audioWindow = WhisperAudioWindow()
    private var lastEmitText = ""
    private var accumulatedText = ""
    private var lastSpeechTime: TimeInterval = 0
    private var decodeInFlight = false
    private var recognitionLocale = "en-US"
    private var hasSpeechInSegment = false
    private var newSamplesSinceDecode = 0
    private var speechRevision = 0
    private var lastAudioDiagnosticsTime: TimeInterval = 0

    private nonisolated(unsafe) static var kitCache: AnyObject?
    private nonisolated(unsafe) static var kitCacheKey: String?
    private static let kitLock = NSLock()

    var running: Bool {
        stateLock.withLock { isRunning }
    }

    var onAccentSamples: (@Sendable ([Float], Int) -> Void)? {
        get { accentTee.onReady }
        set { accentTee.onReady = newValue }
    }

    func setAccentCapture(enabled: Bool) {
        if enabled { accentTee.reset() } else { accentTee.disable() }
    }

    func setSpeakerCapture(enabled: Bool) {
        if enabled { speakerRing.reset() } else { speakerRing.disable() }
    }

    /// Whisper 无热词通道；上下文词仅对 Apple 引擎生效。
    func updateContext(phrases: [String]) {}

    // MARK: - start / stop

    func start(
        localeIdentifier: String,
        contextPhrases: [String],
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void,
        onModelStatus: @escaping @Sendable (String) -> Void,
        onRecognition: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        await stopAsync()
        let epoch = stateLock.withLock { stopEpoch }
        StartupLog.mark("whisper.enter locale=\(localeIdentifier)")

        stateLock.withLock {
            self.recognitionHandler = onRecognition
            self.sampleBuffer = []
            self.audioWindow.reset()
            self.lastEmitText = ""
            self.accumulatedText = ""
            self.lastSpeechTime = 0
            self.decodeInFlight = false
            self.recognitionLocale = localeIdentifier
            self.hasSpeechInSegment = false
            self.newSamplesSinceDecode = 0
            self.speechRevision = 0
            self.lastAudioDiagnosticsTime = 0
        }

        onModelStatus(String(format: String(localized: "Loading %@ speech model…"), Self.displayName))
        StartupLog.mark("whisper.model-load-begin")

        // 首次必须先下完权重（数十秒～数分钟）。进度走 onModelStatus，
        // 不在此处抛错打断下载 —— 否则和录音启动超时互相掐（用户实测）。
        let readyBefore = await MainActor.run { WhisperModelStore.shared.isReady }
        if !readyBefore {
            let poll = Task { @MainActor in
                let store = WhisperModelStore.shared
                while !store.isReady && store.isDownloading {
                    onModelStatus(store.message)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            await WhisperModelStore.shared.download()
            poll.cancel()
            await MainActor.run {
                onModelStatus(WhisperModelStore.shared.message)
            }
        }
        let downloadFailed = await MainActor.run {
            WhisperModelStore.shared.lastError != nil && !WhisperModelStore.shared.isReady
        }
        if downloadFailed {
            let msg = await MainActor.run { WhisperModelStore.shared.message }
            onModelStatus(msg)
            Self.markCreationFailed("model-download")
            stateLock.withLock { self.recognitionHandler = nil }
            throw AudioEngineError.modelUnavailable
        }

        let loaded: Bool = await Task.detached(priority: .userInitiated) {
            await Self.loadKit()
        }.value

        guard loaded else {
            Self.markCreationFailed("whisperkit-load")
            stateLock.withLock { self.recognitionHandler = nil }
            onModelStatus("")
            throw AudioEngineError.modelUnavailable
        }
        StartupLog.mark("whisper.model-load-end")
        onModelStatus(String(format: String(localized: "%@ model ready."), Self.displayName))

        do {
            try await startEngine(
                onInterruption: onInterruption,
                onAudioLevel: onAudioLevel
            )
            StartupLog.mark("whisper.engine-started")
        } catch {
            StartupLog.mark("whisper.engine-failed: \(error.localizedDescription)")
            await stopAsync()
            throw error
        }

        var latestEpoch = epoch
        let superseded = stateLock.withLock { () -> Bool in
            latestEpoch = stopEpoch
            if stopEpoch != epoch { return true }
            isRunning = true
            return false
        }
        if superseded {
            StartupLog.mark("whisper.start-superseded epoch=\(epoch) now=\(latestEpoch)")
            await stopAsync()
            throw CancellationError()
        }
        StartupLog.mark("whisper.start-done")
    }

    func stop() {
        stateLock.withLock {
            stopEpoch += 1
            isRunning = false
            recognitionHandler = nil
        }
        queue.sync {
            self.teardownEngineOnQueue()
        }
    }

    private func stopAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.stateLock.withLock {
                stopEpoch += 1
                isRunning = false
                recognitionHandler = nil
            }
            self.queue.async {
                self.teardownEngineOnQueue()
                cont.resume()
            }
        }
    }

    // MARK: - WhisperKit

    private static func loadKit() async -> Bool {
        let usesCoreML = WhisperModelTier.supportsWhisperRuntime()
        let desiredKey = usesCoreML ? "coreml:\(modelName)" : "onnx:tiny"
        if kitLock.withLock({ kitCache != nil && kitCacheKey == desiredKey }) { return true }
        if !usesCoreML {
            guard WhisperModelStore.onnxModelFilesPresent() else { return false }
            let dir = WhisperModelStore.onnxModelDirectory
            var config = sherpaOnnxOfflineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                modelConfig: sherpaOnnxOfflineModelConfig(
                    tokens: dir.appendingPathComponent("tiny-tokens.txt").path,
                    whisper: sherpaOnnxOfflineWhisperModelConfig(
                        encoder: dir.appendingPathComponent("tiny-encoder.int8.onnx").path,
                        decoder: dir.appendingPathComponent("tiny-decoder.int8.onnx").path,
                        language: "",
                        task: "transcribe"
                    ),
                    numThreads: 2,
                    provider: "cpu"
                )
            )
            let recognizer = SherpaOnnxOfflineRecognizer(config: &config)
            kitLock.withLock {
                kitCache = recognizer
                kitCacheKey = desiredKey
            }
            StartupLog.mark("whisper.kit-ready model=tiny backend=onnx-cpu")
            return true
        }
        #if canImport(WhisperKit)
        do {
            // This branch only runs on a real CoreML-capable Mac. Keep feature
            // extraction on CPU while moving the expensive encoder to ANE and
            // decoder to GPU. The VM takes the ONNX branch above.
            let compute = ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndGPU
            )
            let kit = try await WhisperKit(model: modelName, computeOptions: compute, verbose: false, logLevel: .error)
            kitLock.withLock {
                kitCache = kit
                kitCacheKey = desiredKey
            }
            StartupLog.mark("whisper.kit-ready model=\(modelName) compute=ane+gpu")
            return true
        } catch {
            StartupLog.mark("whisper.kit-load-error \(error.localizedDescription)")
            return false
        }
        #else
        StartupLog.mark("whisper.kit-not-linked")
        return false
        #endif
    }

    #if canImport(WhisperKit)
    private func transcribeWindow(_ samples: [Float], locale: String) async -> String? {
        let cached = Self.kitLock.withLock { Self.kitCache }
        if let recognizer = cached as? SherpaOnnxOfflineRecognizer {
            let result = recognizer.decode(samples: samples, sampleRate: 16_000)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return WhisperTranscriptQuality.accepted(text)
        }
        let kit = cached as? WhisperKit
        guard let kit else { return nil }
        let lang = Self.whisperLanguage(from: locale)
        let options = DecodingOptions(
            task: .transcribe,
            language: lang,
            temperature: 0.0,
            temperatureFallbackCount: 0
        )
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return WhisperTranscriptQuality.accepted(text)
        } catch {
            StartupLog.mark("whisper.transcribe-error \(error.localizedDescription)")
            return nil
        }
    }

    private static func whisperLanguage(from locale: String) -> String {
        let lower = locale.lowercased()
        if lower.hasPrefix("zh") { return "chinese" }
        if lower.hasPrefix("en") { return "english" }
        if lower.hasPrefix("ja") { return "japanese" }
        if lower.hasPrefix("ko") { return "korean" }
        if lower.hasPrefix("fr") { return "french" }
        if lower.hasPrefix("de") { return "german" }
        if lower.hasPrefix("es") { return "spanish" }
        return "english"
    }
    #else
    private func transcribeWindow(_ samples: [Float], locale: String) async -> String? {
        _ = samples
        _ = locale
        return nil
    }
    #endif

    // MARK: - audio tap

    private func startEngine(
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuationStart: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let engine = AVAudioEngine()
                    self.engine = engine
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    StartupLog.mark("whisper.input-format rate=\(format.sampleRate) channels=\(format.channelCount) standard=\(format.isStandard)")
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw AudioEngineError.noInputDevice
                    }
                    let sampleRate = format.sampleRate

                    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                        guard let self else { return }
                        onAudioLevel(Self.rmsLevel(buffer))
                        // 与 Apple/Sherpa 引擎一致：tee/ring 吃 AVAudioPCMBuffer
                        self.accentTee.append(buffer)
                        self.speakerRing.append(buffer)
                        let mono = Self.monoFloats(buffer)
                        self.queue.async {
                            self.ingest(mono: mono, sourceRate: sampleRate)
                        }
                    }
                    self.tapInstalled = true

                    engine.prepare()
                    try engine.start()
                    self.configurationObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange,
                        object: engine,
                        queue: nil
                    ) { [weak self, weak engine] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard let engine, self.engine === engine, !engine.isRunning else { return }
                            let wasRunning = self.running
                            self.stateLock.withLock { self.isRunning = false }
                            if wasRunning { onInterruption() }
                        }
                    }
                    continuationStart.resume()
                } catch {
                    self.teardownEngineOnQueue()
                    continuationStart.resume(throwing: error)
                }
            }
        }
    }

    private func teardownEngineOnQueue() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine, tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        engine?.stop()
        engine = nil
    }

    private static func monoFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        if ch <= 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<ch { sum += data[c][f] }
            out[f] = sum / Float(ch)
        }
        return out
    }

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let ch = min(Int(buffer.format.channelCount), 2)
        var sum: Float = 0
        for c in 0..<ch {
            let ptr = data[c]
            for i in 0..<frames {
                let v = ptr[i]
                sum += v * v
            }
        }
        return sqrt(sum / Float(frames * max(ch, 1)))
    }

    /// 48k/44.1k → 16k 带区间平均的降采样（Whisper 输入）。
    private func ingest(mono: [Float], sourceRate: Double) {
        guard !mono.isEmpty else { return }
        let samples: [Float]
        if abs(sourceRate - 16_000) < 1 {
            samples = mono
        } else {
            samples = AccentClassifier.resample(
                mono,
                from: Int(sourceRate.rounded()),
                to: 16_000
            )
        }

        let now = Date().timeIntervalSince1970
        let rms = samples.reduce(0) { $0 + $1 * $1 }
        let rmsValue = sqrt(rms / Float(max(samples.count, 1)))
        let speech = WhisperDecodePolicy.containsSpeech(
            rms: rmsValue
        )

        let diagnostics: (buffered: Int, fresh: Int, inFlight: Bool)? = stateLock.withLock {
            let admitted = audioWindow.append(samples, isSpeech: speech)
            sampleBuffer = audioWindow.samples
            // Only actual speech should advance the periodic decode clock. Idle
            // and trailing silence used to trigger expensive empty decodes and
            // could evict the utterance while a slow model was still running.
            if speech { newSamplesSinceDecode += admitted }
            if speech {
                lastSpeechTime = now
                hasSpeechInSegment = true
                speechRevision += 1
            }
            guard now - lastAudioDiagnosticsTime >= 1 else { return nil }
            lastAudioDiagnosticsTime = now
            return (sampleBuffer.count, newSamplesSinceDecode, decodeInFlight)
        }
        if let diagnostics {
            StartupLog.mark(
                "whisper.audio rms=\(String(format: "%.5f", rmsValue)) speech=\(speech) buffered=\(diagnostics.buffered) freshSpeech=\(diagnostics.fresh) decoding=\(diagnostics.inFlight)"
            )
        }

        let shouldDecode: Bool = stateLock.withLock {
            WhisperDecodePolicy.shouldDecode(
                hasSpeech: hasSpeechInSegment,
                decodeInFlight: decodeInFlight,
                bufferedSamples: sampleBuffer.count,
                newSamplesSinceDecode: newSamplesSinceDecode,
                silentFor: now - lastSpeechTime
            )
        }
        guard shouldDecode else { return }
        let (window, locale, revision, epoch): ([Float], String, Int, Int) = stateLock.withLock {
            decodeInFlight = true
            newSamplesSinceDecode = 0
            return (sampleBuffer, recognitionLocale, speechRevision, stopEpoch)
        }
        Task { [weak self] in
            guard let self else { return }
            let started = Date().timeIntervalSince1970
            StartupLog.mark("whisper.decode-begin samples=\(window.count) revision=\(revision)")
            let decoded = await self.transcribeWindow(window, locale: locale)
            let elapsed = Date().timeIntervalSince1970 - started
            StartupLog.mark("whisper.decode-end seconds=\(String(format: "%.2f", elapsed)) chars=\(decoded?.count ?? 0)")
            self.finishDecode(
                text: decoded,
                speechRevisionAtDecodeStart: revision,
                epoch: epoch
            )
        }
    }

    private func finishDecode(
        text: String?,
        speechRevisionAtDecodeStart: Int,
        epoch: Int
    ) {
        typealias FollowUp = (samples: [Float], locale: String, revision: Int, epoch: Int)
        let outcome: (
            emission: ((@Sendable (String, Bool) -> Void), String, Bool)?,
            followUp: FollowUp?
        ) = stateLock.withLock {
            // A decoder can finish after stop(), or even after a new recording
            // has started. It must not clear or append to the new session.
            guard stopEpoch == epoch else { return (nil, nil) }
            decodeInFlight = false
            // 累计窗文本：partial 更新；停顿分句时发 final
            let silentFor = Date().timeIntervalSince1970 - lastSpeechTime
            let isFinal = WhisperDecodePolicy.shouldFinalize(
                speechRevisionAtDecodeStart: speechRevisionAtDecodeStart,
                currentSpeechRevision: speechRevision,
                silentFor: silentFor
            )

            let stableText = WhisperTranscriptAccumulator.finalCandidate(
                accumulated: accumulatedText,
                decoded: text
            )
            if !stableText.isEmpty { accumulatedText = stableText }

            var result: ((@Sendable (String, Bool) -> Void), String, Bool)?
            if let handler = recognitionHandler, !stableText.isEmpty,
               stableText != lastEmitText || isFinal {
                lastEmitText = stableText
                result = (handler, stableText, isFinal)
            }

            if isFinal {
                sampleBuffer = []
                audioWindow.reset()
                lastEmitText = ""
                accumulatedText = ""
                hasSpeechInSegment = false
                newSamplesSinceDecode = 0
                speechRevision = 0
            }
            var followUp: FollowUp?
            if !isFinal,
               WhisperDecodePolicy.shouldScheduleFollowUpFinal(
                    speechRevisionAtDecodeStart: speechRevisionAtDecodeStart,
                    currentSpeechRevision: speechRevision,
                    silentFor: silentFor,
                    hasSpeech: hasSpeechInSegment
               ) {
                decodeInFlight = true
                newSamplesSinceDecode = 0
                followUp = (sampleBuffer, recognitionLocale, speechRevision, stopEpoch)
            }
            return (result, followUp)
        }
        StartupLog.mark(
            "whisper.commit decodedChars=\(text?.count ?? 0) emitted=\(outcome.emission != nil) followUp=\(outcome.followUp != nil)"
        )
        // Never invoke app callbacks while holding the engine state lock.
        if let (handler, text, isFinal) = outcome.emission {
            handler(text, isFinal)
        }
        if let followUp = outcome.followUp {
            StartupLog.mark("whisper.decode-follow-up-final revision=\(followUp.revision)")
            Task { [weak self] in
                guard let self else { return }
                let decoded = await self.transcribeWindow(followUp.samples, locale: followUp.locale)
                self.finishDecode(
                    text: decoded,
                    speechRevisionAtDecodeStart: followUp.revision,
                    epoch: followUp.epoch
                )
            }
        }
    }
}
