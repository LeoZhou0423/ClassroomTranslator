import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Captures microphone samples without AVAudioEngine. AVCaptureSession uses a
/// separate capture path and avoids the AVAudioEngine input-node failures seen
/// on macOS 26/27.
final class AudioEngineDriver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.classroomtranslator.audioCapture")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var pump: (@Sendable (CMSampleBuffer) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var interruption: (@Sendable () -> Void)?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionQueue: OperationQueue?

    func start(
        localeIdentifier: String,
        onInterruption: @escaping @Sendable () -> Void,
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
                    recognitionQueue.name = "com.classroomtranslator.speechRecognition"
                    recognitionQueue.maxConcurrentOperationCount = 1
                    recognitionQueue.underlyingQueue = self.queue
                    recognizer.queue = recognitionQueue
                    let task = recognizer.recognitionTask(with: request, resultHandler: onRecognition)

                    guard let device = AVCaptureDevice.default(for: .audio) else {
                        throw AudioEngineError.noInputDevice
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    let session = AVCaptureSession()

                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw AudioEngineError.configurationFailed
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    session.commitConfiguration()

                    self.session = session
                    self.output = output
                    self.recognizer = recognizer
                    self.recognitionQueue = recognitionQueue
                    self.recognitionRequest = request
                    self.recognitionTask = task
                    self.pump = { [weak request] sampleBuffer in
                        request?.appendAudioSampleBuffer(sampleBuffer)
                    }
                    self.interruption = onInterruption
                    self.observe(session)

                    // startRunning is intentionally kept off the main actor.
                    session.startRunning()
                    guard session.isRunning else {
                        throw AudioEngineError.startFailed
                    }
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

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        pump?(sampleBuffer)
    }

    private func observe(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .AVCaptureSessionRuntimeError,
            .AVCaptureSessionWasInterrupted
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: session, queue: nil) { [weak self, weak session] _ in
                guard let self else { return }
                self.queue.async {
                    guard let session, self.session === session else { return }
                    let callback = self.interruption
                    self.stopLocked()
                    callback?()
                }
            }
        }
    }

    private func stopLocked() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        pump = nil
        interruption = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        recognizer = nil
        recognitionQueue?.cancelAllOperations()
        recognitionQueue = nil
        if let session, session.isRunning { session.stopRunning() }
        output = nil
        session = nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session {
            queue.async {
                if session.isRunning { session.stopRunning() }
            }
        }
    }
}

enum AudioEngineError: LocalizedError {
    case noInputDevice
    case configurationFailed
    case startFailed
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return String(localized: "No microphone or audio input device was found.")
        case .configurationFailed:
            return String(localized: "Failed to configure microphone capture.")
        case .startFailed:
            return String(localized: "Failed to start microphone capture.")
        case .recognizerUnavailable:
            return String(localized: "Speech recognition is unavailable on this device.")
        }
    }
}
