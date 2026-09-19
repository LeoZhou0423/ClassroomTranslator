import Foundation
import AVFoundation

/// Engine creation, configuration, notifications and teardown share one queue.
final class AudioEngineDriver {
    private let queue = DispatchQueue(label: "com.classroomtranslator.audioEngine")
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?

    func start(
        onInterruption: @escaping @Sendable () -> Void,
        pump: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.tearDown()
                let engine = AVAudioEngine()
                self.engine = engine
                do {
                    let input = engine.inputNode
                    let hardwareFormat = input.inputFormat(forBus: 0)
                    let format = input.outputFormat(forBus: 0)
                    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
                          format.sampleRate > 0, format.channelCount > 0 else {
                        throw AudioEngineError.formatUnavailable
                    }
                    // Use the node's current format; don't force a stale hardware format.
                    input.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                        pump(buffer)
                    }
                    self.tapInstalled = true
                    self.configurationObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange,
                        object: engine,
                        queue: nil
                    ) { [weak self, weak engine] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard let engine, self.engine === engine, !engine.isRunning else { return }
                            self.tearDown()
                            onInterruption()
                        }
                    }
                    engine.prepare()
                    try engine.start()
                    continuation.resume()
                } catch {
                    self.tearDown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { self.tearDown() }
    }

    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        self.engine = nil
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        // Do not call blocking audio APIs from whichever thread releases the view.
        if let engine {
            let hadTap = tapInstalled
            queue.async {
                if engine.isRunning { engine.stop() }
                if hadTap { engine.inputNode.removeTap(onBus: 0) }
            }
        }
    }
}

enum AudioEngineError: LocalizedError {
    case formatUnavailable

    var errorDescription: String? {
        String(localized: "Invalid audio format")
    }
}
