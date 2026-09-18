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
    
    private var speechRecognizer: SFSpeechRecognizer
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    /// 当前使用的语言代码
    private(set) var currentLanguageCode: String
    
    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "en-GB"
        currentLanguageCode = savedLanguage
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: savedLanguage)) ?? SFSpeechRecognizer()!
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
        
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
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




