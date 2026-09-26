import Foundation
import AVFoundation
import Speech

/// task-6 Step 1：语音引擎协议 SpeechEngine 的 Apple 实现 —— 原
/// AudioEngineDriver 更名而来，公开方法签名零改动（无需转发层）。
/// Owns microphone capture and SpeechAnalyzer transcription on macOS 26+.
/// Replaces the legacy SFSpeechRecognizer pipeline: one long-lived analyzer,
/// hot-updatable AnalysisContext, and progressive volatile/final results
/// without tearing down audio on every final.
final class AppleSpeechEngine: @unchecked Sendable, SpeechEngine {
    typealias RecognitionHandler = @Sendable (_ text: String, _ isFinal: Bool) -> Void

    private let queue = DispatchQueue(label: "com.classroomtranslator.audioSpeech")
    private let stateLock = NSLock()

    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var legacyConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var isRunning = false
    /// 每次 stopAsync 自增；start 用它判断“我这次启动是否已被更晚的 stop 作废”，
    /// 避免 stop 的快照早于 start 写入状态时，引擎被重新拉起后无人关闭。
    private var stopEpoch = 0
    private let accentTee = AccentAudioTee(targetSeconds: 2.5)
    /// 说话人识别取窗环形缓冲（task-4）。tap 里与 accentTee 并联 append。
    let speakerRing = SpeakerAudioRing(capacitySeconds: 30)

    var running: Bool {
        stateLock.withLock { isRunning }
    }

    var onAccentSamples: (@Sendable ([Float], Int) -> Void)? {
        get { accentTee.onReady }
        set { accentTee.onReady = newValue }
    }

    /// Enable/disable the parallel accent buffer for this session.
    func setAccentCapture(enabled: Bool) {
        if enabled {
            accentTee.reset()
        } else {
            accentTee.disable()
        }
    }

    /// 说话人取窗开关：开启时清零绝对采样基准（每次 startRecording 走这里），
    /// 关闭后 append 直接丢弃。功能开关在 SpeechManager 里读设置。
    func setSpeakerCapture(enabled: Bool) {
        if enabled {
            speakerRing.reset()
        } else {
            speakerRing.disable()
        }
    }

    func start(
        localeIdentifier: String,
        contextPhrases: [String],
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void,
        onModelStatus: @escaping @Sendable (String) -> Void,
        onRecognition: @escaping RecognitionHandler
    ) async throws {
        await stopAsync()
        let epoch = stateLock.withLock { stopEpoch }
        StartupLog.mark("driver.enter locale=\(localeIdentifier)")

        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            StartupLog.mark("driver.locale-unsupported")
            throw AudioEngineError.recognizerUnavailable
        }
        StartupLog.mark("driver.locale-ok=\(locale.identifier)")

        let preset = DictationTranscriber.Preset.progressiveLongDictation
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints.union([.farField]),
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions
        )
        StartupLog.mark("driver.transcriber-created")

        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        StartupLog.mark("driver.asset-status=\(String(describing: assetStatus))")
        if assetStatus == .unsupported {
            StartupLog.mark("driver.asset-unsupported")
            throw AudioEngineError.recognizerUnavailable
        }
        if assetStatus != .installed {
            // LOC 4.2：模型状态同样由 NSTextField 承载，必须显式本地化。
            onModelStatus(String(format: String(localized: "Downloading %@ speech model…"), locale.identifier))
            StartupLog.mark("driver.asset-download-begin")
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let throttle = AssetProgressThrottle()
                let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                    guard let percent = throttle.shouldReport(fraction: progress.fractionCompleted) else { return }
                    StartupLog.mark("driver.asset-progress \(percent)%")
                    // %% 才会输出一个字面量 %，否则 String(format:) 会把它当转换说明符。
                    onModelStatus(String(
                        format: String(localized: "Downloading %@ speech model… (%lld%%)"),
                        locale.identifier,
                        percent
                    ))
                }
                defer { observation.invalidate() }
                try await request.downloadAndInstall()
            }
            StartupLog.mark("driver.asset-download-end")
            let recheck = await AssetInventory.status(forModules: [transcriber])
            StartupLog.mark("driver.asset-recheck=\(String(describing: recheck))")
            guard recheck == .installed else {
                StartupLog.mark("driver.asset-not-installed")
                onModelStatus("")
                throw AudioEngineError.recognizerUnavailable
            }
            onModelStatus(String(format: String(localized: "%@ model ready."), locale.identifier))
        } else {
            onModelStatus("")
        }
        StartupLog.mark("driver.assets-done")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        if !contextPhrases.isEmpty {
            context.contextualStrings = [.general: contextPhrases]
        }
        try await analyzer.setContext(context)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            StartupLog.mark("driver.format-unavailable")
            throw AudioEngineError.formatUnavailable
        }
        try await analyzer.prepareToAnalyze(in: format)
        StartupLog.mark("driver.prepared format=\(format.sampleRate)Hz")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    onRecognition(text, result.isFinal)
                }
            } catch is CancellationError {
                // Normal stop.
            } catch {
                guard let self, self.running else { return }
                onInterruption()
            }
        }

        let analysisTask = Task { [weak self] in
            do {
                let lastSample = try await analyzer.analyzeSequence(stream)
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch is CancellationError {
                // Normal stop.
            } catch {
                guard let self, self.running else { return }
                onInterruption()
            }
        }

        stateLock.withLock {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.inputContinuation = continuation
            self.analysisTask = analysisTask
            self.resultsTask = resultsTask
            self.analyzerFormat = format
        }

        do {
            try await startEngine(
                analyzerFormat: format,
                onInterruption: onInterruption,
                onAudioLevel: onAudioLevel
            )
            StartupLog.mark("driver.engine-started")
        } catch {
            StartupLog.mark("driver.engine-failed: \(error.localizedDescription)")
            await stopAsync()
            throw error
        }

        // stop 可能发生在 start 的异步准备阶段（其快照为空、什么也没停）；
        // 只有在写入 isRunning 的同一把锁里比对 epoch，才能保证“晚到的 stop 一定赢”。
        var latestEpoch = epoch
        let superseded = stateLock.withLock { () -> Bool in
            latestEpoch = stopEpoch
            if stopEpoch != epoch { return true }
            isRunning = true
            return false
        }
        if superseded {
            StartupLog.mark("driver.start-superseded epoch=\(epoch) now=\(latestEpoch)")
            await stopAsync()
            throw CancellationError()
        }
        StartupLog.mark("driver.start-done")
    }

    /// Hot-update contextual strings so recognition follows recent lecture content.
    func updateContext(phrases: [String]) {
        let analyzer = stateLock.withLock { self.analyzer }
        guard let analyzer, !phrases.isEmpty else { return }
        Task {
            let context = AnalysisContext()
            context.contextualStrings = [.general: phrases]
            try? await analyzer.setContext(context)
        }
    }

    func stop() {
        Task { await stopAsync() }
    }

    func stopAsync() async {
        accentTee.disable()
        speakerRing.disable()
        let (engine, hadTap, observer, continuation, analysisTask, resultsTask, analyzer) = stateLock.withLock {
            stopEpoch += 1
            isRunning = false
            let engine = self.engine
            let hadTap = tapInstalled
            let observer = configurationObserver
            let continuation = inputContinuation
            let analysisTask = self.analysisTask
            let resultsTask = self.resultsTask
            let analyzer = self.analyzer
            self.engine = nil
            self.tapInstalled = false
            self.configurationObserver = nil
            self.inputContinuation = nil
            self.analysisTask = nil
            self.resultsTask = nil
            self.analyzer = nil
            self.transcriber = nil
            self.legacyConverter = nil
            self.analyzerFormat = nil
            return (engine, hadTap, observer, continuation, analysisTask, resultsTask, analyzer)
        }

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        if let engine, hadTap {
            queue.sync {
                if engine.isRunning { engine.stop() }
                engine.inputNode.removeTap(onBus: 0)
            }
        } else if let engine, engine.isRunning {
            queue.sync { engine.stop() }
        }

        continuation?.finish()
        analysisTask?.cancel()
        resultsTask?.cancel()
        _ = await analysisTask?.value
        _ = await resultsTask?.value
        await analyzer?.cancelAndFinishNow()
    }

    private func startEngine(
        analyzerFormat: AVAudioFormat,
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        guard let continuation = currentContinuation() else {
            throw AudioEngineError.startFailed
        }

        try await withCheckedThrowingContinuation { (continuationStart: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard AVCaptureDevice.default(for: .audio) != nil else {
                        throw AudioEngineError.noInputDevice
                    }
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0,
                          format.channelCount > 0,
                          format.streamDescription.pointee.mBytesPerFrame > 0,
                          format.isStandard else {
                        throw AudioEngineError.formatUnavailable
                    }

                    guard let converter = AVAudioConverter(from: format, to: analyzerFormat) else {
                        throw AudioEngineError.formatUnavailable
                    }
                    self.stateLock.withLock {
                        self.legacyConverter = converter
                    }

                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        guard let self else { return }
                        self.yield(buffer: buffer, analyzerFormat: analyzerFormat, continuation: continuation)
                        self.accentTee.append(buffer)
                        self.speakerRing.append(buffer)
                        guard let channel = buffer.floatChannelData?.pointee else { return }
                        let count = Int(buffer.frameLength)
                        guard count > 0 else { return }
                        var sum: Float = 0
                        for index in 0..<count { sum += channel[index] * channel[index] }
                        let rms = sqrt(sum / Float(count))
                        onAudioLevel(min(1, max(0, rms * 8)))
                    }

                    engine.prepare()
                    try engine.start()
                    guard engine.isRunning else { throw AudioEngineError.startFailed }

                    self.stateLock.lock()
                    self.engine = engine
                    self.tapInstalled = true
                    self.configurationObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange,
                        object: engine,
                        queue: nil
                    ) { [weak self, weak engine] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard let engine, self.engine === engine, !engine.isRunning else { return }
                            let wasRunning = self.running
                            self.stateLock.lock()
                            self.isRunning = false
                            self.stateLock.unlock()
                            if wasRunning {
                                onInterruption()
                            }
                        }
                    }
                    self.stateLock.unlock()

                    continuationStart.resume()
                } catch {
                    continuationStart.resume(throwing: error)
                }
            }
        }
    }

    private func currentContinuation() -> AsyncStream<AnalyzerInput>.Continuation? {
        stateLock.withLock { inputContinuation }
    }

    private func yield(
        buffer: AVAudioPCMBuffer,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let converter = stateLock.withLock { legacyConverter }
        guard let converter else { return }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var fed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        let engine = self.engine
        let hadTap = tapInstalled
        let continuation = inputContinuation
        let analysisTask = self.analysisTask
        let resultsTask = self.resultsTask
        let analyzer = self.analyzer
        continuation?.finish()
        analysisTask?.cancel()
        resultsTask?.cancel()
        Task {
            await analyzer?.cancelAndFinishNow()
            if let engine {
                if engine.isRunning { engine.stop() }
                if hadTap { engine.inputNode.removeTap(onBus: 0) }
            }
        }
    }
}

enum AudioEngineError: LocalizedError {
    case formatUnavailable
    case startFailed
    case recognizerUnavailable
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return String(localized: "Invalid audio format")
        case .startFailed:
            return String(localized: "Failed to start the audio engine")
        case .recognizerUnavailable:
            return String(localized: "Speech recognition is unavailable on this device.")
        case .noInputDevice:
            return String(localized: "No microphone or audio input device was found.")
        }
    }
}

private final class AssetProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReportedAt: TimeInterval = 0

    func shouldReport(fraction: Double) -> Int? {
        guard fraction.isFinite else { return nil }
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        guard now - lastReportedAt >= 1 else { return nil }
        lastReportedAt = now
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * 100).rounded(.down))
    }
}
