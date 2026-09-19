import Foundation
import AVFoundation
import Speech

/// Owns the complete microphone and Speech pipeline on one background queue.
/// AVAudioEngine provides PCM buffers in the format expected by Speech; none of
/// its potentially blocking setup work runs on the main thread.
final class AudioEngineDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.classroomtranslator.audioSpeech")
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionQueue: OperationQueue?

    func start(
        localeIdentifier: String,
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void,
        onRecognition: @escaping @Sendable (SFSpeechRecognitionResult?, Error?) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.stopLocked()
                do {
                    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
                          recognizer.isAvailable else {
                        throw AudioEngineError.recognizerUnavailable
                    }

                    let request = SFSpeechAudioBufferRecognitionRequest()
                    request.shouldReportPartialResults = true
                    request.taskHint = .dictation
                    let recognitionQueue = OperationQueue()
                    recognitionQueue.name = "com.classroomtranslator.speechResults"
                    recognitionQueue.maxConcurrentOperationCount = 1
                    recognitionQueue.underlyingQueue = self.queue
                    recognizer.queue = recognitionQueue
                    let recognitionTask = recognizer.recognitionTask(with: request, resultHandler: onRecognition)

                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw AudioEngineError.formatUnavailable
                    }
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak request] buffer, _ in
                        request?.append(buffer)
                        guard let channel = buffer.floatChannelData?.pointee else { return }
                        let count = Int(buffer.frameLength)
                        guard count > 0 else { return }
                        var sum: Float = 0
                        for index in 0..<count { sum += channel[index] * channel[index] }
                        let rms = sqrt(sum / Float(count))
                        onAudioLevel(min(1, max(0, rms * 8)))
                    }
                    self.tapInstalled = true

                    self.engine = engine
                    self.recognizer = recognizer
                    self.recognitionQueue = recognitionQueue
                    self.recognitionRequest = request
                    self.recognitionTask = recognitionTask
                    self.configurationObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange,
                        object: engine,
                        queue: nil
                    ) { [weak self, weak engine] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard let engine, self.engine === engine, !engine.isRunning else { return }
                            self.stopLocked()
                            onInterruption()
                        }
                    }

                    engine.prepare()
                    try engine.start()
                    guard engine.isRunning else { throw AudioEngineError.startFailed }
                    continuation.resume()
                } catch {
                    self.stopLocked()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    private func stopLocked() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        recognizer = nil
        recognitionQueue?.cancelAllOperations()
        recognitionQueue = nil

        if let engine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        engine = nil
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        guard let engine else { return }
        let hadTap = tapInstalled
        queue.async {
            if engine.isRunning { engine.stop() }
            if hadTap { engine.inputNode.removeTap(onBus: 0) }
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
