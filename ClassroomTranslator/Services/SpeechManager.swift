import Foundation
import Speech
import AVFoundation

@MainActor
@Observable
final class SpeechManager {
    var isRecording = false
    var currentText = ""
    var onSegmentRecognized: ((String, Bool) -> Void)?
    /// 录音被系统打断（锁屏/睡眠/音频设备变化/识别服务报错）时回调，
    /// UI 层据此把状态同步回来，避免界面卡在"录音中"
    var onRecordingInterrupted: (() -> Void)?
    /// 语言模型状态变化回调（UI 显示"正在下载模型..."等提示）
    var onLanguageModelStatusChanged: ((String) -> Void)?
    var onAudioLevelChanged: ((Float) -> Void)?

    private let driver = AudioEngineDriver()

    /// 说话人识别取窗缓冲（task-4）：录音页的 SpeakerEngine 直接读它。
    var speakerRing: SpeakerAudioRing { driver.speakerRing }
    private var isStarting = false
    private var recordingGeneration = 0

    private var debounceWorkItem: DispatchWorkItem?
    private var lastPartialText = ""
    /// Last complete recognizer snapshot already committed to the transcript.
    private var committedText = ""
    private var contextCourseName = ""
    private let accentClassifier: AccentClassifier?
    private var accentDetectionTask: Task<Void, Never>?
    private var accentDetectionActive = false

    private(set) var currentLanguageCode: String

    init() {
        var savedLanguage = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "auto"
        // 收口：老配置可能残留已移除的非英语口音码（auto/auto-detect/未知码都归入 Auto）
        if LanguageOptions.supportedSource(savedLanguage) == "auto" {
            savedLanguage = Self.safeAutomaticEnglishLocale()
        }
        currentLanguageCode = savedLanguage
        accentClassifier = AccentClassifier(bundle: .module)
    }

    /// Course title feeds AnalysisContext so domain words bias recognition.
    func configureContext(courseName: String) {
        contextCourseName = courseName
    }

    private func handleConfigurationChange() {
        guard isRecording || isStarting else { return }
        stopRecording()
        onRecordingInterrupted?()
    }

    private func resetPauseModel(clearRecognitionContext: Bool = false) {
        lastPartialText = ""
        if clearRecognitionContext { committedText = "" }
    }

    /// 切换识别语言（口音）。"auto" 不是合法 locale，直接忽略
    /// （Auto 走 startAutoDetectRecording，不走这里）。
    func switchLanguage(to languageCode: String) {
        guard languageCode != currentLanguageCode else { return }
        guard languageCode != "auto", languageCode != "auto-detect" else { return }
        currentLanguageCode = languageCode
        onLanguageModelStatusChanged?("")
    }

    static let allEnglishLocales = [
        "en-US", "en-GB", "en-AU", "en-NZ", "en-IE", "en-ZA", "en-CA", "en-IN"
    ]

    static func safeAutomaticEnglishLocale() -> String {
        AccentClassifier.defaultLocale
    }

    func downloadAllEnglishModels() async -> (ready: Int, total: Int) {
        var ready = 0
        let total = Self.allEnglishLocales.count
        let installed = Set(await DictationTranscriber.installedLocales.map(\.identifier))

        for (index, code) in Self.allEnglishLocales.enumerated() {
            if installed.contains(code) {
                ready += 1
                continue
            }
            guard let locale = await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: code)
            ) else { continue }

            let transcriber = DictationTranscriber(
                locale: locale,
                preset: .progressiveLongDictation
            )
            // LOC 4.2：状态行是 NSTextField.stringValue，不会查表，必须显式本地化。
            onLanguageModelStatusChanged?(String(
                format: String(localized: "Downloading %@… (%lld/%lld)"),
                code,
                index + 1,
                total
            ))
            let status = await AssetInventory.status(forModules: [transcriber])
            if status == .installed {
                ready += 1
                continue
            }
            if status == .unsupported { continue }
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
            if await AssetInventory.status(forModules: [transcriber]) == .installed {
                ready += 1
            }
        }

        onLanguageModelStatusChanged?(String(
            format: String(localized: "%lld/%lld English models ready."),
            ready,
            total
        ))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        onLanguageModelStatusChanged?("")
        return (ready, total)
    }

    func requestSpeechPermission() async -> Bool {
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String,
              !usage.isEmpty else {
            StartupLog.mark("sm.speech-usage-missing")
            return false
        }
        StartupLog.mark("sm.permission-speech-request status=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                StartupLog.mark("sm.permission-speech-result=\(status.rawValue)")
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func requestMicPermission() async -> Bool {
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
              !usage.isEmpty else {
            StartupLog.mark("sm.mic-usage-missing")
            return false
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            StartupLog.mark("sm.permission-mic-authorized")
            return true
        case .notDetermined:
            StartupLog.mark("sm.permission-mic-request")
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                    StartupLog.mark("sm.permission-mic-result=\(granted)")
                    continuation.resume(returning: granted)
                }
            }
        default:
            StartupLog.mark("sm.permission-mic-status=\(status.rawValue)")
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

        StartupLog.mark("sm.start-recording locale=\(currentLanguageCode)")
        guard AVCaptureDevice.default(for: .audio) != nil else {
            StartupLog.mark("sm.no-input-device")
            throw SpeechError.noInputDevice
        }

        let phrases = currentContextPhrases()
        do {
            try await driver.start(
                localeIdentifier: currentLanguageCode,
                contextPhrases: phrases,
                onInterruption: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.recordingGeneration == generation else { return }
                        self.handleConfigurationChange()
                    }
                },
                onAudioLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.onAudioLevelChanged?(level)
                    }
                },
                onModelStatus: { [weak self] message in
                    Task { @MainActor in
                        self?.onLanguageModelStatusChanged?(message)
                    }
                },
                onRecognition: { [weak self] text, isFinal in
                    Task { @MainActor in
                        guard let self, self.recordingGeneration == generation else { return }
                        self.handleRecognition(text: text, isFinal: isFinal)
                    }
                }
            )
        } catch {
            StartupLog.mark("sm.driver-start-failed: \(error.localizedDescription)")
            stopRecording()
            // stopRecording() 会作废本次启动，别把 CancellationError 的原始
            // localizedDescription 直接抛给界面（会显示成 "Swift.CancellationError error 1"）。
            if error is CancellationError { throw SpeechError.startSuperseded }
            throw error
        }
        guard recordingGeneration == generation else {
            // 启动期间已被 stopRecording()（20s 超时 / 设备变化 / 用户结束）作废，
            // 但底层 driver.start 刚把引擎和麦克风拉起来，必须再停一次，
            // 否则界面显示"启动失败"后麦克风仍持续占用。
            StartupLog.mark("sm.start-superseded generation=\(generation)")
            driver.stop()
            throw SpeechError.startSuperseded
        }
        // 说话人取窗只受设置开关控制（模型缺失时引擎自然惰性，数据白读成本为零）。
        driver.setSpeakerCapture(enabled: SpeakerDetectionConfiguration().isEnabled)
        isRecording = true
        StartupLog.mark("sm.recording-started")
    }

    private func currentContextPhrases() -> [String] {
        RecognitionContextProvider.phrases(
            courseName: contextCourseName,
            recentText: committedText
        )
    }

    private func handleRecognition(text: String, isFinal: Bool) {
        if isFinal {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            commitFinal(text)
        } else {
            updatePartial(fullText: text)
        }
    }

    private func commitFinal(_ finalText: String) {
        var delta: String
        if committedText.isEmpty {
            delta = finalText
            committedText = finalText
        } else if finalText.hasPrefix(committedText) {
            delta = RecognitionTextDelta.unseenText(after: committedText, in: finalText)
            committedText = finalText
        } else {
            let extensionDelta = RecognitionTextDelta.unseenText(after: committedText, in: finalText)
            if extensionDelta != finalText, !extensionDelta.isEmpty, finalText.hasSuffix(extensionDelta) {
                // Cumulative snapshot that extends committed text via revision anchor.
                delta = extensionDelta
                committedText = finalText
            } else if RecognitionTextDelta.unseenText(after: "", in: finalText) == finalText
                        && !wordSequenceContains(committedText, finalText) {
                // Independent finalized passage for a later audio range.
                delta = finalText
                committedText = committedText + " " + finalText
            } else {
                // Already committed (short correction / replay).
                delta = extensionDelta
                if extensionDelta.isEmpty {
                    currentText = ""
                    resetPauseModel()
                    return
                }
                committedText = finalText
            }
        }

        let cleaned = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            currentText = ""
            resetPauseModel()
            return
        }

        let units = SentenceSplitter.commitUnits(from: cleaned)
        for unit in units {
            let piece = unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            onSegmentRecognized?(piece, true)
        }

        currentText = ""
        resetPauseModel()
        pushContextUpdate()
    }

    private func wordSequenceContains(_ haystack: String, _ needle: String) -> Bool {
        let normalize: (String) -> String = {
            $0.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).joined(separator: " ")
        }
        let h = normalize(haystack)
        let n = normalize(needle)
        return !n.isEmpty && h.contains(n)
    }

    private func updatePartial(fullText: String) {
        guard fullText != lastPartialText else { return }
        lastPartialText = fullText

        var text: String
        if committedText.isEmpty {
            text = fullText
        } else {
            text = RecognitionTextDelta.unseenText(after: committedText, in: fullText)
            // Range-only volatile hypothesis after committed finals: show as new tail.
            if text.isEmpty, !fullText.isEmpty, !fullText.hasPrefix(committedText) {
                let candidate = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty, !committedText.contains(candidate) {
                    text = candidate
                }
            }
        }
        guard !text.isEmpty else { return }
        currentText = text
        onSegmentRecognized?(text, false)
        scheduleFallbackCommit(fullText: fullText, visibleText: text)
    }

    /// 只在长时间无新结果时才提交（fallback），正常情况靠 isFinal 提交
    private func scheduleFallbackCommit(fullText: String, visibleText: String) {
        debounceWorkItem?.cancel()
        let delay: TimeInterval = {
            if SentenceSplitter.hasSentenceEnding(visibleText) { return 1.2 }
            if visibleText.count >= 100 { return 2.0 }
            return 3.0
        }()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording, self.lastPartialText == fullText else { return }
                self.commitFinal(fullText)
            }
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func pushContextUpdate() {
        driver.updateContext(phrases: currentContextPhrases())
    }

    func stopRecording() {
        recordingGeneration += 1
        accentDetectionActive = false
        accentDetectionTask?.cancel()
        accentDetectionTask = nil
        driver.onAccentSamples = nil
        driver.setAccentCapture(enabled: false)
        driver.setSpeakerCapture(enabled: false)
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        resetPauseModel(clearRecognitionContext: true)
        driver.stop()
        isRecording = false
    }

    func clearSegments() {
        currentText = ""
        resetPauseModel(clearRecognitionContext: true)
    }

    // MARK: - Auto language compatibility

    func startAutoDetectRecording() async throws {
        StartupLog.mark("sm.auto-enter")
        UserDefaults.standard.removeObject(forKey: "detectedRecognitionLanguage")
        currentLanguageCode = Self.safeAutomaticEnglishLocale()
        accentDetectionActive = false
        driver.onAccentSamples = nil
        try await startRecording()

        guard let accentClassifier else {
            StartupLog.mark("sm.accent-classifier-unavailable")
            driver.setAccentCapture(enabled: false)
            return
        }

        let generation = recordingGeneration
        driver.onAccentSamples = { [weak self] samples, sampleRate in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.recordingGeneration == generation else { return }
                self.classifyAccent(samples, sampleRate: sampleRate, generation: generation, classifier: accentClassifier)
            }
        }
        driver.setAccentCapture(enabled: true)
    }

    private func classifyAccent(
        _ samples: [Float],
        sampleRate: Int,
        generation: Int,
        classifier: AccentClassifier
    ) {
        guard !accentDetectionActive else { return }
        accentDetectionActive = true
        driver.setAccentCapture(enabled: false)

        accentDetectionTask?.cancel()
        accentDetectionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                classifier.classify(monoSamples: samples, sampleRate: sampleRate)
            }.value

            guard !Task.isCancelled, let self else { return }
            await self.applyDetectedAccent(result, generation: generation)
        }
    }

    private func applyDetectedAccent(_ result: AccentClassifier.Result?, generation: Int) async {
        guard let result,
              isRecording,
              recordingGeneration == generation else { return }

        let locale = result.localeIdentifier
        guard result.confidence >= AccentClassifier.confidenceThreshold,
              locale != currentLanguageCode else {
            onLanguageModelStatusChanged?("")
            return
        }

        onLanguageModelStatusChanged?(String(
            format: String(localized: "Detected %@ (%@)…"),
            locale,
            result.accent
        ))
        UserDefaults.standard.set(locale, forKey: "detectedRecognitionLanguage")
        currentLanguageCode = locale
        driver.onAccentSamples = nil

        if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitFinal(currentText)
        }
        let savedCommittedText = committedText
        isRecording = false
        do {
            try await startRecording()
            onLanguageModelStatusChanged?(String(format: String(localized: "Detected %@."), locale))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onLanguageModelStatusChanged?("")
        } catch {
            committedText = savedCommittedText
            isRecording = false
            onRecordingInterrupted?()
        }
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
    case startSuperseded

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
        case .startSuperseded:
            return String(localized: "The recording was stopped before it finished starting.")
        }
    }
}
