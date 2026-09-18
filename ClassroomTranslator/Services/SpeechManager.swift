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
    /// （那是“正在启动录音…”假死、全屏黑屏的根因）
    private let driver = AudioEngineDriver()

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

        // 没有可用输入设备时快速失败，而不是挂着
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
                        self.finalSegments.append(text)
                        self.currentText = ""
                        self.onSegmentRecognized?(text, true)
                    } else {
                        self.currentText = text
                        self.onSegmentRecognized?(text, false)
                    }
                }

                if error != nil {
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

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(localized: "Invalid audio format")
        case .requestCreationFailed:
            return String(localized: "Failed to create recognition request")
        case .engineStartFailed:
            return String(localized: "Failed to start the audio engine")
        }
    }
}