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

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// 音频引擎全部在后台队列跑，避免 start() 阻塞主线程
    /// （那是"正在启动录音…"假死、全屏黑屏的根因）
    private let driver = AudioEngineDriver()
    private var isStarting = false
    private var recordingGeneration = 0

    // MARK: - 自适应停顿检测模型
    private var debounceWorkItem: DispatchWorkItem?
    private var lastPartialText = ""
    private var lastPartialTime: TimeInterval = 0
    private var emaInterval: Double = 0
    private var intervalCount = 0
    private var minInterval: Double = 0.3
    private let emaAlpha = 0.4
    private let kBase = 4.0
    private let kMin = 2.5
    private let warmupThreshold = 3
    private let warmupPause: TimeInterval = 1.5
    /// 句末标点集合（断句必须有这些才真正分句）
    private static let sentenceEndingPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ".", "!", "?", ".", "!", "?", ")", "]", "」", "』", "\"", "'", "\u{201D}", "\u{2019}"]

    /// 判断文本是否以句末标点结尾（真正完成了一个完整句意）
    private static func hasSentenceEnding(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        // 句末标点直接返回
        if sentenceEndingPunctuation.contains(last) { return true }
        // 英文缩写不误判（如 "U.S." "Dr."）—— 检查倒数第二个字符
        if last == "." && trimmed.count >= 3 {
            let idx = trimmed.index(trimmed.endIndex, offsetBy: -2)
            if trimmed[idx].isUppercase { return false }
        }
        return false
    }

    /// 当前使用的语言代码
    private(set) var currentLanguageCode: String

    init() {
        var savedLanguage = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "en-GB"
        // "auto" 不是合法 locale，绝不能拿去建识别器（之前这里 force unwrap 会崩）
        if savedLanguage == "auto" || savedLanguage == "auto-detect" {
            savedLanguage = "en-US"
        }
        currentLanguageCode = savedLanguage
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: savedLanguage))
            ?? SFSpeechRecognizer()
        if speechRecognizer == nil {
            print("Warning: no speech recognizer available on this device")
        }

    }

    /// 音频配置变化（锁屏/睡眠/插拔设备）时，录音已经没了，收尾并通知 UI
    private func handleConfigurationChange() {
        guard isRecording || isStarting else { return }
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

    /// 切换识别语言（口音）。"auto" 不是合法 locale，直接忽略
    /// （Auto 走 startAutoDetectRecording，不走这里）。
    func switchLanguage(to languageCode: String) {
        guard languageCode != currentLanguageCode else { return }
        guard languageCode != "auto", languageCode != "auto-detect" else { return }

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
                // 等待模型下载完成（最多15秒）
                for _ in 0..<15 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if recognizer.supportsOnDeviceRecognition {
                        ready += 1
                        break
                    }
                }
            }
        }
        onLanguageModelStatusChanged?("\(ready)/\(total) English models ready.")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        onLanguageModelStatusChanged?("")
        return (ready, total)
    }

    func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
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
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func startRecording() async throws {
        guard !isStarting else { throw SpeechError.startInProgress }
        if isRecording { return }
        isStarting = true
        recordingGeneration += 1
        let generation = recordingGeneration
        defer { isStarting = false }

        // 识别器不可用（设备不支持/被限制）：直接报，不崩
        guard let recognizer = speechRecognizer else {
            throw SpeechError.recognizerUnavailable
        }

        // 没有麦克风/输入设备时直接失败，而不是访问引擎触发异常崩溃
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw SpeechError.noInputDevice
        }

        guard recognizer.isAvailable else { throw SpeechError.recognizerUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recordingGeneration == generation else { return }

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

                            // ---- 停顿检测：有句末标点时断句 ----
                            let pauseDetected: Bool
                            if self.lastPartialTime > 0, self.intervalCount >= self.warmupThreshold {
                                pauseDetected = gap > threshold && Self.hasSentenceEnding(text)
                            } else {
                                pauseDetected = self.lastPartialTime > 0 && gap > self.warmupPause && Self.hasSentenceEnding(text)
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
                                    // debounce 超时也检查句末标点
                                    guard Self.hasSentenceEnding(text) || text.count > 60 else { return }
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
            try await driver.start(onInterruption: { [weak self] in
                Task { @MainActor in
                    guard let self, self.recordingGeneration == generation else { return }
                    self.handleConfigurationChange()
                }
            }) { [weak request] buffer in
                request?.appendAudioSampleBuffer(buffer)
            }
        } catch {
            stopRecording()
            throw error
        }
        guard recordingGeneration == generation else { throw CancellationError() }
        isRecording = true
    }

    func stopRecording() {
        // Invalidate callbacks before cancel(), including a start still awaiting the engine.
        recordingGeneration += 1
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        resetPauseModel()
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

    // MARK: - Auto language compatibility

    /// macOS Speech does not expose safe live locale detection. Running several
    /// SFSpeechRecognitionTasks against one microphone can deadlock speech services
    /// on macOS 26/27, so Auto deliberately uses one stable English recognizer.
    func startAutoDetectRecording() async throws {
        let locale = Self.safeAutomaticEnglishLocale()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            throw SpeechError.recognizerUnavailable
        }
        speechRecognizer = recognizer
        currentLanguageCode = locale
        try await startRecording()
    }

    private static func safeAutomaticEnglishLocale() -> String {
        let region = Locale.current.region?.identifier ?? "US"
        let candidate = "en-\(region)"
        return allEnglishLocales.contains(candidate) ? candidate : "en-US"
    }

    func stopAutoDetectRecording() {
        stopRecording()
    }

}

enum SpeechError: LocalizedError {
    case startInProgress
    case invalidFormat
    case requestCreationFailed
    case engineStartFailed
    case permissionDeniedSpeech
    case permissionDeniedMic
    case noInputDevice
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .startInProgress:
            return String(localized: "The previous recording is still starting. Please wait.")
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
        case .recognizerUnavailable:
            return String(localized: "Speech recognition is unavailable on this device.")
        }
    }
}
