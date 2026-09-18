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
    private let audioEngine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    /// 是否有已安装的输入 tap，防止重复 removeTap 崩溃 / start 挂死
    private var hasTap = false
    
    /// 当前使用的语言代码
    private(set) var currentLanguageCode: String
    
    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "en-GB"
        currentLanguageCode = savedLanguage
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: savedLanguage)) ?? SFSpeechRecognizer()!
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }
    
    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
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
    
    func startRecording() throws {
        if isRecording { return }
        
        // 防御性复位：上次录音被打断（锁屏/睡眠/识别报错）时可能残留
        // tap/运行中的 engine，直接 start 会挂死，先清干净
        if hasTap { audioEngine.inputNode.removeTap(onBus: 0); hasTap = false }
        if audioEngine.isRunning { audioEngine.stop() }
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        guard recordingFormat.sampleRate > 0 else {
            throw SpeechError.invalidFormat
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechError.requestCreationFailed
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        
        // // // // var finalText = ""
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    let isFinal = result.isFinal
                    
                    if isFinal {
                        // // // // finalText = text
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
        
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16000,
                                    channels: 1,
                                    interleaved: false)!
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        hasTap = true
        
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        audioEngine.stop()
        if hasTap { audioEngine.inputNode.removeTap(onBus: 0); hasTap = false }
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
    
    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(localized: "Invalid audio format")
        case .requestCreationFailed:
            return String(localized: "Failed to create recognition request")
        }
    }
}




