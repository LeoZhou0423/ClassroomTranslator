import Foundation
import AVFoundation
import SherpaOnnx

/// task-6 Step 2：语音引擎协议 SpeechEngine 的 sherpa-onnx 实现。
///
/// 架构（EngineArchitecture.md §3/§5，Lead 已批）：
///  · mic 互斥 —— 引擎单实例（工厂在 SpeechManager init 时按设置分叉），
///    永不双开 AVAudioEngine、永不中途切换；
///  · 口音 tee + 说话人环与 Apple 引擎同构，挂在本引擎 tap 层，只经协议面暴露；
///  · 模型创建在 start() 的 detached 任务里完成（1.6s 级加载不冻结主线程），
///    走 onModelStatus("Loading…"/"…model ready.") 与 Apple 下载状态同一文案形状；
///  · 降级纪律同 task-4：模型资源缺失 / 创建识别器失败 → 熔断（进程内
///    isUsable=false）→ 工厂下次回退 apple 并记日志；任何 sherpa 故障都不
///    影响默认 apple 路径。
///
/// C API 调用序列以 SHERPA-DEMO.md 行号版为准（Lead 要求不凭记忆）：
/// config → SherpaOnnxRecognizer.init（create recognizer + stream）→
/// acceptWaveform(16k, [-1,1]) → isReady()/decode() 循环 → getResult().text →
/// isEndpoint() → final + reset() → inputFinished/drain（离线收尾，实时不用）。
/// 注意：上游 wrapper 的 init 对 C 创建失败是 trap 而非 nil，所以进入创建前
/// 必须做文件齐全 + 最小体积校验（已跑通的同批模型，截断风险见 §5 已知局限）。
final class SherpaSpeechEngine: @unchecked Sendable, SpeechEngine {
    // MARK: - 模型资源与可用性

    /// Package.swift `.copy("Resources/SherpaStreamEN")` 的目录名。
    static let modelDirectory = "SherpaStreamEN"

    /// 英语流式 zipformer（int8, chunk-16-left-128）：配置实际引用的文件 +
    /// 最小体积（防截断；wrapper 对 C 失败是 trap，这里必须先挡住）。
    static let requiredModelFiles: [(name: String, minBytes: Int64)] = [
        ("encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx", 60_000_000),
        ("decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx", 1_000_000),
        ("joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx", 200_000),
        ("tokens.txt", 1_000)
    ]

    private static let availabilityLock = NSLock()
    /// 创建失败熔断：进程内不再尝试 sherpa（工厂回退 apple）。与 task-4 的
    /// 模型缺失降级是同一纪律，不触碰 SpeechManager 编排。
    private static var creationDisabled = false

    static func modelDirectoryURL(bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: modelDirectory, withExtension: nil)
    }

    static func modelsPresent(bundle: Bundle = .module) -> Bool {
        guard let dir = modelDirectoryURL(bundle: bundle) else { return false }
        let fm = FileManager.default
        return requiredModelFiles.allSatisfy { file in
            let path = dir.appendingPathComponent(file.name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64 else { return false }
            return size >= file.minBytes
        }
    }

    /// 工厂/设置页/单测共用的可用性判断：未熔断 且 模型文件齐全。
    static func isUsable(bundle: Bundle = .module) -> Bool {
        let disabled = availabilityLock.withLock { creationDisabled }
        return !disabled && modelsPresent(bundle: bundle)
    }

    private static func markCreationFailed(_ reason: String) {
        availabilityLock.withLock { creationDisabled = true }
        StartupLog.mark("sherpa.creation-failed reason=\(reason)")
    }

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.classroomtranslator.sherpaAsr")
    private let stateLock = NSLock()

    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var converter: AVAudioConverter?
    private var sherpaFormat: AVAudioFormat?
    /// 识别器跨 start 复用（start 前 reset），随引擎释放而销毁。
    private var recognizer: SherpaOnnxRecognizer?
    private var isRunning = false
    /// 与 AppleSpeechEngine 同语义：晚到的 stop 必须赢。
    private var stopEpoch = 0

    private var recognitionHandler: (@Sendable (String, Bool) -> Void)?
    /// 只在 queue 上读写（decode 串行）。
    private var lastEmittedText = ""

    private let accentTee = AccentAudioTee(targetSeconds: 2.5)
    let speakerRing = SpeakerAudioRing(capacitySeconds: 30)

    var running: Bool {
        stateLock.withLock { isRunning }
    }

    var onAccentSamples: (@Sendable ([Float], Int) -> Void)? {
        get { accentTee.onReady }
        set { accentTee.onReady = newValue }
    }

    func setAccentCapture(enabled: Bool) {
        if enabled {
            accentTee.reset()
        } else {
            accentTee.disable()
        }
    }

    func setSpeakerCapture(enabled: Bool) {
        if enabled {
            speakerRing.reset()
        } else {
            speakerRing.disable()
        }
    }

    /// sherpa MVP 无热词/上下文注入通道（EngineArchitecture.md §5 注明）。
    func updateContext(phrases: [String]) {}

    // MARK: - SpeechEngine.start

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
        StartupLog.mark("sherpa.enter locale=\(localeIdentifier)")

        // sherpa 模型固定英语（HEAD 输入即英语+口音 only），locale 仅记日志。
        // 模型缺失在此再挡一道（工厂已挡；熔断后下次工厂直接回退 apple）。
        guard let modelDir = Self.modelDirectoryURL(), Self.modelsPresent() else {
            Self.markCreationFailed("model-missing-at-start")
            onModelStatus("")
            throw AudioEngineError.recognizerUnavailable
        }

        stateLock.withLock {
            self.recognitionHandler = onRecognition
        }

        onModelStatus(String(format: String(localized: "Loading %@ speech model…"), "sherpa-onnx"))
        StartupLog.mark("sherpa.model-load-begin")

        // 复用上一次 start 创建的识别器；否则后台线程新建（约 1.6s，不冻结主线程）。
        var recognizer = stateLock.withLock { self.recognizer }
        if recognizer == nil {
            recognizer = await Task.detached(priority: .userInitiated) {
                Self.makeRecognizer(modelDir: modelDir)
            }.value
        }
        guard let recognizer else {
            Self.markCreationFailed("recognizer-creation")
            stateLock.withLock { self.recognitionHandler = nil }
            onModelStatus("")
            throw AudioEngineError.recognizerUnavailable
        }
        // 队列此刻无消费者（上一段 stopAsync 已 queue.sync 排空、tap 未装）。
        recognizer.reset()
        stateLock.withLock { self.recognizer = recognizer }
        StartupLog.mark("sherpa.model-load-end")
        onModelStatus(String(format: String(localized: "%@ model ready."), "sherpa-onnx"))

        do {
            try await startEngine(
                sherpaSampleRate: 16_000,
                onInterruption: onInterruption,
                onAudioLevel: onAudioLevel
            )
            StartupLog.mark("sherpa.engine-started")
        } catch {
            StartupLog.mark("sherpa.engine-failed: \(error.localizedDescription)")
            await stopAsync()
            throw error
        }

        // 与 AppleSpeechEngine 相同的 epoch 收尾：晚到的 stop 必须赢。
        var latestEpoch = epoch
        let superseded = stateLock.withLock { () -> Bool in
            latestEpoch = stopEpoch
            if stopEpoch != epoch { return true }
            isRunning = true
            return false
        }
        if superseded {
            StartupLog.mark("sherpa.start-superseded epoch=\(epoch) now=\(latestEpoch)")
            await stopAsync()
            throw CancellationError()
        }
        StartupLog.mark("sherpa.start-done")
    }

    /// 校验通过后创建识别器；校验不充分时宁可返回 nil 走熔断，
    /// 也不让上游 wrapper 的 C 失败 trap 打崩进程。
    /// internal：单测在无麦 CI 环境用真实模型跑通「配置→C 创建→释放」全链路。
    static func makeRecognizer(modelDir: URL) -> SherpaOnnxRecognizer? {
        let fm = FileManager.default
        for file in requiredModelFiles {
            let path = modelDir.appendingPathComponent(file.name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64, size >= file.minBytes else {
                StartupLog.mark("sherpa.model-invalid file=\(file.name)")
                return nil
            }
        }

        let encoder = modelDir.appendingPathComponent("encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx").path
        let decoder = modelDir.appendingPathComponent("decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx").path
        let joiner = modelDir.appendingPathComponent("joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx").path
        let tokens = modelDir.appendingPathComponent("tokens.txt").path

        // SHERPA-DEMO.md §B2：config 组装（feature 16k/80 + transducer +
        // numThreads=2（demo 延迟数据的配置）+ endpoint 分句）。
        // rule1/2/3 = 2.0 / 1.0 / 30：课堂语速下停顿 2s 结束句子、30s 强制
        // 切句，可在 EngineArchitecture.md §5 调参。
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
            modelConfig: sherpaOnnxOnlineModelConfig(
                tokens: tokens,
                transducer: sherpaOnnxOnlineTransducerModelConfig(
                    encoder: encoder,
                    decoder: decoder,
                    joiner: joiner
                ),
                numThreads: 2,
                provider: "cpu"
            ),
            enableEndpoint: true,
            rule1MinTrailingSilence: 2.0,
            rule2MinTrailingSilence: 1.0,
            rule3MinUtteranceLength: 30
        )
        return SherpaOnnxRecognizer(config: &config)
    }

    // MARK: - 音频引擎（与 AppleSpeechEngine 的 startEngine 同构）

    private func startEngine(
        sherpaSampleRate: Double,
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
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

                    // sherpa 只吃 16k 单声道 float（Apple 的目标格式是
                    // SpeechAnalyzer bestAvailable，这里是固定模型输入格式）。
                    guard let sherpaFormat = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: sherpaSampleRate,
                        channels: 1,
                        interleaved: false
                    ) else {
                        throw AudioEngineError.formatUnavailable
                    }
                    guard let converter = AVAudioConverter(from: format, to: sherpaFormat) else {
                        throw AudioEngineError.formatUnavailable
                    }
                    self.stateLock.withLock {
                        self.converter = converter
                        self.sherpaFormat = sherpaFormat
                    }

                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        guard let self else { return }
                        self.feed(buffer: buffer, sherpaFormat: sherpaFormat)
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

    /// 设备缓冲 → 16k 单声道 → 串行队列解码（与 Apple 的 yield 同构）。
    private func feed(buffer: AVAudioPCMBuffer, sherpaFormat: AVAudioFormat) {
        let converter = stateLock.withLock { self.converter }
        guard let converter else { return }

        let ratio = sherpaFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: sherpaFormat, frameCapacity: capacity) else { return }
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
        guard let channel = converted.floatChannelData?.pointee else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            self?.decode(samples)
        }
    }

    /// queue 上串行执行：喂样本 → 解码 → 部分/句末回调 → endpoint 复位。
    /// 守门用 recognitionHandler 而非 running：与 Apple 同构 —— tap 装上到
    /// epoch 写入 isRunning 之间的块不能丢（首字延迟已受模型上下文制约）；
    /// stop 后 handler 置 nil，等效于不再回调。
    private func decode(_ samples: [Float]) {
        let snapshot: (SherpaOnnxRecognizer?, (@Sendable (String, Bool) -> Void)?) =
            stateLock.withLock { (self.recognizer, self.recognitionHandler) }
        guard let recognizer = snapshot.0, let onRecognition = snapshot.1 else { return }

        recognizer.acceptWaveform(samples: samples, sampleRate: 16_000)
        while recognizer.isReady() {
            recognizer.decode()
        }

        let text = recognizer.getResult().text
        if !text.isEmpty, text != lastEmittedText {
            lastEmittedText = text
            onRecognition(text, false)
        }

        // endpoint 分句：发出当前整句 as final 后复位，后续为下一句的 partial。
        if recognizer.isEndpoint() {
            if !text.isEmpty {
                onRecognition(text, true)
            }
            recognizer.reset()
            lastEmittedText = ""
        }
    }

    // MARK: - stop

    func stop() {
        Task { await stopAsync() }
    }

    func stopAsync() async {
        accentTee.disable()
        speakerRing.disable()
        let (engine, hadTap, observer) = stateLock.withLock {
            stopEpoch += 1
            isRunning = false
            let engine = self.engine
            let hadTap = tapInstalled
            let observer = configurationObserver
            self.engine = nil
            self.tapInstalled = false
            self.configurationObserver = nil
            self.converter = nil
            self.sherpaFormat = nil
            self.recognitionHandler = nil
            return (engine, hadTap, observer)
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
        lastEmittedText = ""
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        let engine = self.engine
        let hadTap = tapInstalled
        Task {
            if let engine {
                if engine.isRunning { engine.stop() }
                if hadTap { engine.inputNode.removeTap(onBus: 0) }
            }
        }
    }
}
