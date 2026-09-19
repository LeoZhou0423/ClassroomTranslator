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
    /// UI 层据此把状态同步回来，避免界面卡在“录音中”
    var onRecordingInterrupted: (() -> Void)?

    private var speechRecognizer: SFSpeechRecognizer
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// 音频引擎全部在后台队列跑，避免 start() 阻塞主线程
    /// （那是"正在启动录音…"假死、全屏黑屏的根因）
    private let driver = AudioEngineDriver()
    /// 停顿检测：根据语速自适应阈值
    private var debounceWorkItem: DispatchWorkItem?
    private var partialTimestamps: [TimeInterval] = []   // 最近 N 次 partial 的时间戳
    private var lastPartialText = ""

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

    /// 切换识别语言（口音）
    func switchLanguage(to languageCode: String) {
        guard languageCode != currentLanguageCode else { return }

        if let newRecognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode)) {
            speechRecognizer = newRecognizer
            currentLanguageCode = languageCode
            print("Switched speech recognizer to: \(languageCode)")
        } else {
            print("Warning: Cannot create recognizer for \(languageCode)")
        }
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
                        self.partialTimestamps.removeAll()
                        self.lastPartialText = ""
                        self.finalSegments.append(text)
                        self.currentText = ""
                        self.onSegmentRecognized?(text, true)
                    } else {
                        let now = ProcessInfo.processInfo.systemUptime
                        // 只在文本实际变化时记录（忽略 recognizer 重复回调同一条）
                        if text != self.lastPartialText {
                            self.partialTimestamps.append(now)
                            if self.partialTimestamps.count > 10 { self.partialTimestamps.removeFirst() }
                            self.lastPartialText = text
                        }

                        // 算语速：每秒字符数（取最近几次更新的平均间隔）
                        let charsPerSecond: Double
                        if self.partialTimestamps.count >= 2 {
                            let intervals = zip(self.partialTimestamps.dropFirst(), self.partialTimestamps.dropLast())
                            let avgInterval = intervals.map(-).reduce(0, +) / Double(self.partialTimestamps.count - 1)
                            let totalChars = Double(text.count)
                            let totalTime = avgInterval * Double(self.partialTimestamps.count - 1)
                            charsPerSecond = totalTime > 0 ? totalChars / totalTime : 3.0
                        } else {
                            charsPerSecond = 3.0  // 默认中等语速
                        }

                        // 停顿阈值 = 自适应：语速越快阈值越短，越慢越长
                        //   快速说话 (6 cps) → ~1.5s
                        //   中等 (3 cps)   → ~2.5s
                        //   慢速 (1.5 cps) → ~4s
                        let pauseThreshold = max(1.2, min(5.0, 8.0 / max(charsPerSecond, 0.5)))

                        self.debounceWorkItem?.cancel()
                        if text.count >= 3 {
                            let workItem = DispatchWorkItem { [weak self] in
                                guard let self else { return }
                                guard self.isRecording else { return }
                                // 停顿达到阈值，当 final 处理，触发翻译
                                self.partialTimestamps.removeAll()
                                self.lastPartialText = ""
                                self.finalSegments.append(text)
                                self.currentText = ""
                                self.onSegmentRecognized?(text, true)
                            }
                            self.debounceWorkItem = workItem
                            DispatchQueue.main.asyncAfter(deadline: .now() + pauseThreshold, execute: workItem)
                        }
                        self.currentText = text
                        self.onSegmentRecognized?(text, false)
                    }
                }

                if error != nil {
                    self.debounceWorkItem?.cancel()
                    self.debounceWorkItem = nil
                    self.partialTimestamps.removeAll()
                    self.lastPartialText = ""
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