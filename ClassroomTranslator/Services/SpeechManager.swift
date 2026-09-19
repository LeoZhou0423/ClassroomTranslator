import Foundation
import Speech
import AVFoundation

@MainActor
@Observable
final class SpeechManager {
    var isRecording = false
    var currentText = ""
    var finalSegments: [String] = []
    var onSegmentRecognized: ((String, Bool) -> Void)?
    /// 录音被系统打断（锁屏/睡眠/音频设备变化/识别服务报错）时回调，
    /// UI 层据此把状态同步回来，避免界面卡在"录音中"
    var onRecordingInterrupted: (() -> Void)?
    /// 语言模型状态变化回调（UI 显示"正在下载模型..."等提示）
    var onLanguageModelStatusChanged: ((String) -> Void)?

    private var speechRecognizer: SFSpeechRecognizer
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// 音频引擎全部在后台队列跑，避免 start() 阻塞主线程
    /// （那是"正在启动录音…"假死、全屏黑屏的根因）
    private let driver = AudioEngineDriver()

    // MARK: - 自适应停顿检测模型
    // 用 EMA 跟踪 partial result 的更新间隔，动态判断"停顿"
    private var debounceWorkItem: DispatchWorkItem?
    private var lastPartialText = ""
    private var lastPartialTime: TimeInterval = 0
    private var emaInterval: Double = 0       // 指数移动平均：最近更新间隔
    private var intervalCount = 0             // 已收集的间隔数（越多越自信）
    private var minInterval: Double = 0.3     // 动态下限：快速说话也不会误判
    private let emaAlpha = 0.3                // 平滑系数（越大越跟踪最新值）
    private let kBase = 3.5                   // 基础倍数：间隔的几倍算停顿
    private let kMin = 2.0                    // 最小倍数（数据多时收紧）
    private let warmupThreshold = 5           // 前 N 次用保守值

    /// 当前使用的语言代码
    private(set) var currentLanguageCode: String

    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "en-GB"
        currentLanguageCode = savedLanguage
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: savedLanguage)) ?? SFSpeechRecognizer()!
        // SpeechManager 与主窗口同生命周期；用 block 观察者 + Task 跳回主 actor，
        // 避免在非隔离回调里直接碰 MainActor 内容
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: driver.engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
    }

    /// 音频配置变化（锁屏/睡眠/插拔设备）时，录音已经没了，收尾并通知 UI
    private func handleConfigurationChange() {
        guard isRecording else { return }
        stopRecording()
        onRecordingInterrupted?()
    }

    private func resetPauseModel() {
        emaInterval = 0
        intervalCount = 0
        minInterval = 0.3
        lastPartialTime = 0
        lastPartialText = ""
    }

    /// 切换识别语言（口音）。系统会自动下载对应模型，这里加提示。
    func switchLanguage(to languageCode: String) {
        guard languageCode != currentLanguageCode else { return }

        if let newRecognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode)) {
            speechRecognizer = newRecognizer
            currentLanguageCode = languageCode
            print("Switched speech recognizer to: \(languageCode)")

            // 检查模型是否就绪，未就绪时通知 UI 显示下载提示
            Task {
                await checkAndNotifyModelStatus(newRecognizer, languageCode: languageCode)
            }
        } else {
            print("Warning: Cannot create recognizer for \(languageCode)")
            onLanguageModelStatusChanged?("Speech recognition is not available for this language.")
        }
    }

    /// 检查模型状态并通知 UI
    private func checkAndNotifyModelStatus(_ recognizer: SFSpeechRecognizer, languageCode: String) async {
        // supportsOnDeviceRecognition = false 说明模型未下载
        if recognizer.supportsOnDeviceRecognition {
            onLanguageModelStatusChanged?("")  // 就绪，清空提示
        } else {
            onLanguageModelStatusChanged?("Downloading \(languageCode) speech model…")
            // 等几秒让系统开始下载，再检查一次
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if recognizer.supportsOnDeviceRecognition {
                onLanguageModelStatusChanged?("\(languageCode) model ready.")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                onLanguageModelStatusChanged?("")
            } else {
                onLanguageModelStatusChanged?("\(languageCode) model is downloading in the background. You can start recording — it will work once the model finishes.")
            }
        }
    }

    /// Auto 模式：批量下载所有英语口音模型
    static let allEnglishLocales = [
        "en-US", "en-GB", "en-AU", "en-NZ", "en-IE", "en-ZA", "en-CA", "en-IN"
    ]

    func downloadAllEnglishModels() async -> (ready: Int, total: Int) {
        var ready = 0
        let total = Self.allEnglishLocales.count
        for code in Self.allEnglishLocales {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: code)) else { continue }
            if recognizer.supportsOnDeviceRecognition {
                ready += 1
            } else {
                // 触发系统下载（创建实例即可，系统自动开始）
                _ = recognizer
                onLanguageModelStatusChanged?("Downloading \(code)… (\(ready + 1)/\(total))")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if recognizer.supportsOnDeviceRecognition { ready += 1 }
            }
        }
        onLanguageModelStatusChanged?("\(ready)/\(total) English models ready.")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        onLanguageModelStatusChanged?("")
        return (ready, total)
    }

    func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func requestMicPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func startRecording() async throws {
        if isRecording { return }

        // 没有麦克风/输入设备时直接失败，而不是访问引擎触发异常崩溃
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw SpeechError.noInputDevice
        }

        // 输入格式异常也快速失败
        let inputNode = driver.engine.inputNode
        guard inputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            throw SpeechError.invalidFormat
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    let isFinal = result.isFinal

                    if isFinal {
                        self.debounceWorkItem?.cancel()
                        self.debounceWorkItem = nil
                        self.resetPauseModel()
                        self.finalSegments.append(text)
                        self.currentText = ""
                        self.onSegmentRecognized?(text, true)
                    } else {
                        let now = ProcessInfo.processInfo.systemUptime

                        if text != self.lastPartialText {
                            let gap = now - self.lastPartialTime
                            // ---- 更新 EMA 模型 ----
                            if self.lastPartialTime > 0 {
                                if self.intervalCount == 0 {
                                    self.emaInterval = gap
                                } else {
                                    self.emaInterval = self.emaAlpha * gap + (1 - self.emaAlpha) * self.emaInterval
                                }
                                self.intervalCount += 1
                                self.minInterval = max(0.2, self.emaInterval * 0.3)
                            }
                            self.lastPartialTime = now
                            self.lastPartialText = text

                            // ---- 计算停顿阈值 ----
                            let threshold: Double
                            if self.intervalCount < self.warmupThreshold {
                                threshold = 2.0
                            } else {
                                let confidence = min(1.0, Double(self.intervalCount - self.warmupThreshold) / 20.0)
                                let k = self.kBase - (self.kBase - self.kMin) * confidence
                                threshold = max(self.minInterval * 2, self.emaInterval * k)
                            }

                            // ---- 停顿检测 ----
                            let pauseDetected: Bool
                            if self.lastPartialTime > 0, self.intervalCount >= self.warmupThreshold {
                                pauseDetected = gap > threshold
                            } else {
                                pauseDetected = self.lastPartialTime > 0 && gap > 2.0
                            }

                            if pauseDetected && text.count >= 3 {
                                self.debounceWorkItem?.cancel()
                                self.finalSegments.append(text)
                                self.currentText = ""
                                self.onSegmentRecognized?(text, true)
                            } else {
                                // 还在说话：重置 debounce 计时器
                                self.debounceWorkItem?.cancel()
                                let workItem = DispatchWorkItem { [weak self] in
                                    guard let self, self.isRecording else { return }
                                    self.resetPauseModel()
                                    self.finalSegments.append(text)
                                    self.currentText = ""
                                    self.onSegmentRecognized?(text, true)
                                }
                                self.debounceWorkItem = workItem
                                DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: workItem)
                            }
                        }
                        self.currentText = text
                        self.onSegmentRecognized?(text, false)
                    }
                }

                if error != nil {
                    self.debounceWorkItem?.cancel()
                    self.debounceWorkItem = nil
                    self.resetPauseModel()
                    self.stopRecording()
                    self.onRecordingInterrupted?()
                }
            }
        }

        // 引擎启动放后台队列；慢/失败都不占用主线程
        do {
            try await driver.start { [weak request] buffer in
                request?.append(buffer)
            }
        } catch {
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            throw SpeechError.engineStartFailed
        }
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }

        driver.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    func clearSegments() {
        finalSegments.removeAll()
        currentText = ""
    }
}

enum SpeechError: LocalizedError {
    case invalidFormat
    case requestCreationFailed
    case engineStartFailed
    case permissionDeniedSpeech
    case permissionDeniedMic
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(localized: "Invalid audio format")
        case .requestCreationFailed:
            return String(localized: "Failed to create recognition request")
        case .engineStartFailed:
            return String(localized: "Failed to start the audio engine")
        case .permissionDeniedSpeech:
            return String(localized: "Speech recognition permission was denied.")
        case .permissionDeniedMic:
            return String(localized: "Microphone permission was denied.")
        case .noInputDevice:
            return String(localized: "No microphone or audio input device was found.")
        }
    }
}