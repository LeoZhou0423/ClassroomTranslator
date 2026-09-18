import AVFoundation

/// 音频引擎独立驱动器。
/// 所有可能阻塞的音频 API（installTap/prepare/start/stop）都在专用后台
/// 队列执行，绝不占用主线程，避免“点开始卡死 / 全屏假死”。
/// 非 actor 隔离，无并发编译告警；引擎所有权都在这类内部。
final class AudioEngineDriver {
    private let queue = DispatchQueue(label: "com.classroomtranslator.audioEngine")
    private var _tapInstalled = false
    private var pump: ((AVAudioPCMBuffer) -> Void)?
    private let _engine = AVAudioEngine()

    /// 供外部监听配置变化（设备切换/睡眠/插拔），只读取引擎对象本身
    var engine: AVAudioEngine { _engine }

    /// 在后台队列启动引擎，成功则持续把麦克风 buffer 喂给 pump。
    /// 只在引擎真正起来或抛错时才结束，正常情况不会阻塞调用方。
    func start(pump: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self._engine.isRunning { self._engine.stop() }
                    if self._tapInstalled {
                        self._engine.inputNode.removeTap(onBus: 0)
                        self._tapInstalled = false
                    }
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: false)
                    guard let format else {
                        throw AudioEngineError.formatUnavailable
                    }
                    self._engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        self?.pump?(buffer)
                    }
                    self._tapInstalled = true
                    self.pump = pump
                    self._engine.prepare()
                    try self._engine.start()
                    cont.resume(returning: ())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 异步收尾：停引擎、摘 tap、清回调。不等待，绝不阻塞调用方。
    func stop() {
        queue.async {
            self.pump = nil
            if self._engine.isRunning { self._engine.stop() }
            if self._tapInstalled {
                self._engine.inputNode.removeTap(onBus: 0)
                self._tapInstalled = false
            }
        }
    }

    deinit {
        // deinit 无法强同步清理，这里再做一次兜底
        if _engine.isRunning { _engine.stop() }
    }
}

enum AudioEngineError: Error {
    case formatUnavailable
}