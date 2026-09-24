import Foundation
import AVFoundation
import Speech

/// Owns microphone capture and SpeechAnalyzer transcription on macOS 26+.
/// Replaces the legacy SFSpeechRecognizer pipeline: one long-lived analyzer,
/// hot-updatable AnalysisContext, and progressive volatile/final results
/// without tearing down audio on every final.
final class AudioEngineDriver: @unchecked Sendable {
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
    private var audioConverter27: Any?
    private var legacyConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var isRunning = false
    private let accentTee = AccentAudioTee(targetSeconds: 2.5)

    var running: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
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

    func start(
        localeIdentifier: String,
        contextPhrases: [String],
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void,
        onModelStatus: @escaping @Sendable (String) -> Void,
        onRecognition: @escaping RecognitionHandler
    ) async throws {
        await stopAsync()

        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw AudioEngineError.recognizerUnavailable
        }

        let preset = DictationTranscriber.Preset.progressiveLongDictation
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints.union([.farField]),
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions
        )

        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if assetStatus == .unsupported {
            throw AudioEngineError.recognizerUnavailable
        }
        if assetStatus != .installed {
            onModelStatus("Downloading \(locale.identifier) speech model…")
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let recheck = await AssetInventory.status(forModules: [transcriber])
            if recheck == .unsupported {
                onModelStatus("")
                throw AudioEngineError.recognizerUnavailable
            }
            onModelStatus(recheck == .installed ? "\(locale.identifier) model ready." : "")
        } else {
            onModelStatus("")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        if !contextPhrases.isEmpty {
            context.contextualStrings = [.general: contextPhrases]
        }
        try await analyzer.setContext(context)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AudioEngineError.formatUnavailable
        }
        try await analyzer.prepareToAnalyze(in: format)

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

        stateLock.lock()
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputContinuation = continuation
        self.analysisTask = analysisTask
        self.resultsTask = resultsTask
        self.analyzerFormat = format
        stateLock.unlock()

        do {
            try await startEngine(
                modules: [transcriber],
                analyzerFormat: format,
                onInterruption: onInterruption,
                onAudioLevel: onAudioLevel
            )
        } catch {
            await stopAsync()
            throw error
        }

        stateLock.lock()
        isRunning = true
        stateLock.unlock()
    }

    /// Hot-update contextual strings so recognition follows recent lecture content.
    func updateContext(phrases: [String]) {
        stateLock.lock()
        let analyzer = self.analyzer
        stateLock.unlock()
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
        stateLock.lock()
        isRunning = false
        // Fresh session should be able to capture accent audio again if re-armed.
        accentTee.disable()
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
        self.audioConverter27 = nil
        self.legacyConverter = nil
        self.analyzerFormat = nil
        stateLock.unlock()

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
        modules: [any SpeechModule],
        analyzerFormat: AVAudioFormat,
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        guard let continuation = currentContinuation() else {
            throw AudioEngineError.startFailed
        }

        let converter: Any?
        if #available(macOS 27, *) {
            let c = try await AnalyzerInputConverter.converter(compatibleWith: modules)
            converter = c
            stateLock.lock()
            audioConverter27 = c
            legacyConverter = nil
            stateLock.unlock()
        } else {
            let engineProbe = AVAudioEngine()
            let inputFormat = engineProbe.inputNode.outputFormat(forBus: 0)
            guard let avConverter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                throw AudioEngineError.formatUnavailable
            }
            converter = avConverter
            stateLock.lock()
            audioConverter27 = nil
            legacyConverter = avConverter
            stateLock.unlock()
        }
        _ = converter

        try await withCheckedThrowingContinuation { (continuationStart: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw AudioEngineError.formatUnavailable
                    }

                    // Rebuild legacy converter against the live input format.
                    if #available(macOS 27, *) {
                        // AnalyzerInputConverter handles format conversion.
                    } else {
                        guard let avConverter = AVAudioConverter(from: format, to: analyzerFormat) else {
                            throw AudioEngineError.formatUnavailable
                        }
                        self.stateLock.lock()
                        self.legacyConverter = avConverter
                        self.stateLock.unlock()
                    }

                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        guard let self else { return }
                        self.yield(buffer: buffer, analyzerFormat: analyzerFormat, continuation: continuation)
                        self.accentTee.append(buffer)
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
        stateLock.lock()
        defer { stateLock.unlock() }
        return inputContinuation
    }

    private func yield(
        buffer: AVAudioPCMBuffer,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        if #available(macOS 27, *) {
            stateLock.lock()
            let converter = audioConverter27 as? AnalyzerInputConverter
            stateLock.unlock()
            guard let converter else { return }
            do {
                for input in try converter.convert(buffer, at: nil) {
                    continuation.yield(input)
                }
            } catch {
                // Drop buffers that cannot convert; next buffers may recover.
            }
            return
        }

        stateLock.lock()
        let converter = legacyConverter
        stateLock.unlock()
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

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return String(localized: "Invalid audio format")
        case .startFailed:
            return String(localized: "Failed to start the audio engine")
        case .recognizerUnavailable:
            return String(localized: "Speech recognition is unavailable on this device.")
        }
    }
}
