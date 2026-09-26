import SwiftUI
import AppKit

/// A fixed AppKit recording surface. It deliberately avoids SwiftUI controls,
/// conditional view trees and bindings while recording because those enter an
/// infinite NSHostingView layout loop on affected macOS 26/27 builds.
struct StableRecordingView: NSViewControllerRepresentable {
    let course: Course
    let historyStore: HistoryStore
    let translationManager: TranslationManager
    let onClose: () -> Void

    func makeNSViewController(context: Context) -> StableRecordingViewController {
        StableRecordingViewController(
            course: course,
            historyStore: historyStore,
            translationManager: translationManager,
            onClose: onClose
        )
    }

    func updateNSViewController(_ controller: StableRecordingViewController, context: Context) {
        // All live state is owned by the AppKit controller. Reassigning controls
        // here would reconnect the SwiftUI layout feedback path.
    }

    static func dismantleNSViewController(_ controller: StableRecordingViewController, coordinator: ()) {
        controller.shutDown()
    }
}

@MainActor
final class StableRecordingViewController: NSViewController {
    private let course: Course
    /// 值类型快照：课程被删除后不能再读 course 的属性（SwiftData 会 fatal error）。
    private let courseID: UUID
    private let historyStore: HistoryStore
    private let translationManager: TranslationManager
    private let onClose: () -> Void
    private let speechManager = SpeechManager()
    private let subtitleWindow = SubtitleWindowController()

    private let transcriptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0:00:00")
    private let levelIndicator = NSProgressIndicator()
    private let startButton = NSButton(title: String(localized: "Start"), target: nil, action: nil)
    private let pauseButton = NSButton(title: String(localized: "Pause"), target: nil, action: nil)
    private let endButton = NSButton(title: String(localized: "End Session"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "Back"), target: nil, action: nil)
    private let overlayButton = NSButton(title: String(localized: "Hide Overlay"), target: nil, action: nil)
    /// UX-03：权限被拒后给出「打开系统设置」恢复路径；默认隐藏，只在权限失败时出现。
    private let openSettingsButton = NSButton(title: String(localized: "Open System Settings"), target: nil, action: nil)
    /// PSY-06：状态区常驻小字，说明自动保存节奏，避免真丢数据时被理解成"数据丢失 bug"。
    private let autosaveHint = NSTextField(labelWithString: String(localized: "Auto-saves every 30 seconds"))
    /// VIS-01/VIS-07：电平条前的麦克风图标，不靠 tooltip 也能自明。
    private let micIconView = NSImageView()
    /// task-4：控制条上的「当前说话人」（纯 AppKit；detachesHiddenViews 收起空位）。
    private let speakerLabel = NSTextField(labelWithString: "")
    /// task-4：说话人识别引擎。模型缺失时 init 置 nil → 段落无标签，只能手动标注。
    private var speakerEngine: SpeakerEngine?

    private var sessionState = RecordingSessionState()
    private var activeRecord: TranscriptRecord?
    private var finalizedText = ""
    /// VIS-02：与 finalizedText 同源但带样式 —— 原文降级、译文强调，
    /// 同时保证每次写入都带显式 attributes（否则 NSTextView 可能回落到 12pt）。
    private var finalizedAttributed = NSAttributedString()
    private var renderedFinalizedText = ""
    private var liveTranscriptRange: NSRange?
    private var hasRenderedTranscript = false
    private var partialText = ""
    private var partialTranslation = ""
    private var translationCoordinator: LiveTranslationCoordinator!
    private var partialRevision = 0
    private var generation = 0
    private var startupStep: RecordingStartupStep?
    private var timer: Timer?
    private var checkpointTimer: Timer?
    private var overlayVisible = true
    private var lastEnqueuedFinalRevision = -1
    private var translationGeneration = 0
    private var minimumValidPartialRevision = 0
    /// UX-04：结束阶段的状态行刷新定时器（显示还剩几段翻译 / 正在保存）。
    private var endingTimer: Timer?
    /// UX-03：最近一次权限失败对应的设置深链，供状态栏常驻按钮复用。
    private var permissionRecoveryURL: URL?

    /// 课程被删除时它下面的录音记录会被 cascade 删除；此后任何对 activeRecord
    /// 的属性访问都可能命中 SwiftData "backing data could no longer be found"
    /// 的 fatal error。HistoryStore.deleteCourse 会登记被删的课程，用它做闸门。
    private var courseExists: Bool {
        historyStore.isCourseAlive(courseID)
    }

    init(course: Course, historyStore: HistoryStore, translationManager: TranslationManager, onClose: @escaping () -> Void) {
        self.course = course
        self.courseID = course.id
        self.historyStore = historyStore
        self.translationManager = translationManager
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        translationCoordinator = LiveTranslationCoordinator { [weak self] text in
            guard let self else { return "" }
            return await self.translationManager.translate(text)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.bezelStyle = .rounded
        overlayButton.target = self
        overlayButton.action = #selector(toggleOverlayPressed)
        overlayButton.bezelStyle = .rounded

        let title = NSTextField(labelWithString: course.name)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let accent = NSTextField(labelWithString: "\(course.accentName) → \(course.targetLanguageName)")
        accent.textColor = .secondaryLabelColor

        // PSY-06：把"每 30 秒自动保存"摆到明面上；空间不够时先截断这行小字，
        // 保证课程标题和返回按钮永远优先。
        autosaveHint.font = .systemFont(ofSize: 11)
        autosaveHint.textColor = .tertiaryLabelColor
        autosaveHint.lineBreakMode = .byTruncatingTail
        autosaveHint.setContentHuggingPriority(.required, for: .horizontal)
        autosaveHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [closeButton, title, accent, autosaveHint])
        header.orientation = .horizontal
        header.spacing = 12
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.minSize = NSSize(width: 0, height: 240)
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.font = .systemFont(ofSize: 15)
        transcriptView.textColor = .labelColor
        transcriptView.backgroundColor = .textBackgroundColor
        transcriptView.textContainerInset = NSSize(width: 12, height: 12)
        // VIS-02：占位文案也带显式 attributes，避免 NSTextView 回落到默认 12pt。
        transcriptView.textStorage?.setAttributedString(NSAttributedString(
            string: String(localized: "Ready to Listen"),
            attributes: Self.originalTextAttributes
        ))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = transcriptView
        transcriptView.frame = NSRect(x: 0, y: 0, width: 640, height: 240)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // VIS-01：错误类状态允许换行，不再被 byTruncatingTail 吃掉关键信息。
        statusLabel.usesSingleLineMode = false
        statusLabel.maximumNumberOfLines = 1
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        levelIndicator.style = .bar
        levelIndicator.minValue = 0
        levelIndicator.maxValue = 1
        levelIndicator.doubleValue = 0
        levelIndicator.toolTip = String(localized: "Microphone input level")
        levelIndicator.widthAnchor.constraint(equalToConstant: 96).isActive = true

        // task-4：当前说话人标签，默认隐藏（无识别结果时不占位）。
        speakerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        speakerLabel.textColor = .secondaryLabelColor
        speakerLabel.isHidden = true

        // VIS-07：电平条加图标前缀，一眼能看出这根条量的是麦克风。
        micIconView.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: String(localized: "Microphone input level")
        )
        micIconView.contentTintColor = .secondaryLabelColor
        micIconView.translatesAutoresizingMaskIntoConstraints = false
        micIconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        micIconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        // UX-03：默认隐藏，failStart(权限类) 时才出现。
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsPressed)
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.isHidden = true

        startButton.target = self
        startButton.action = #selector(startPressed)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        pauseButton.target = self
        pauseButton.action = #selector(pausePressed)
        pauseButton.bezelStyle = .rounded
        endButton.target = self
        endButton.action = #selector(endPressed)
        endButton.bezelStyle = .rounded

        let controls = NSStackView(views: [statusLabel, micIconView, levelIndicator, elapsedLabel, speakerLabel, overlayButton, startButton, pauseButton, endButton, openSettingsButton])
        controls.orientation = .horizontal
        controls.spacing = 12
        // UX-03：隐藏的"打开系统设置"按钮不能在控制条里留出空位。
        controls.detachesHiddenViews = true
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, scroll, controls])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        view = root
        configureSpeakerEngine()
        configureCallbacks()
        renderState()
    }

    /// UX-03：权限失败时把用户送到系统设置对应隐私面板。
    private static let speechPrivacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    )
    private static let microphonePrivacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    @objc private func startPressed() {
        guard sessionState.phase == .idle || sessionState.phase == .paused || sessionState.phase == .interrupted else { return }
        beginRecording()
    }

    private func beginRecording() {
        generation += 1
        let currentGeneration = generation
        sessionState.beginStarting()
        // 权限弹窗可能停留很久；期间课程若被删除，后面就再不能读 course 的属性了。
        let accentCode = course.accentCode
        speechManager.configureContext(courseName: course.name)
        openSettingsButton.isHidden = true
        permissionRecoveryURL = nil
        setStatus(String(localized: "Requesting speech recognition permission…"))
        renderState()
        StartupLog.markEnvironment()
        StartupLog.mark("ui.begin accent=\(course.accentCode)")
        let speechUsage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        let micUsage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        guard let speechUsage, !speechUsage.isEmpty, let micUsage, !micUsage.isEmpty else {
            StartupLog.mark("ui.usage-missing speech=\(speechUsage != nil) mic=\(micUsage != nil)")
            failStart(
                String(localized: "App package is missing speech/microphone usage descriptions. Reinstall the packaged app."),
                generation: currentGeneration
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            StartupLog.mark("ui.request-speech-permission")
            guard await speechManager.requestSpeechPermission() else {
                StartupLog.mark("ui.speech-permission-denied")
                // UX-03：启用 .strings 里一直躺着没被引用的长引导文案，并给出深链。
                failStart(
                    String(localized: "Speech recognition permission was denied. Please allow it in System Settings → Privacy & Security → Speech Recognition, then try again."),
                    generation: currentGeneration,
                    permissionURL: Self.speechPrivacyURL
                )
                return
            }
            setStatus(String(localized: "Requesting microphone permission…"))
            StartupLog.mark("ui.request-mic-permission")
            guard await speechManager.requestMicPermission() else {
                StartupLog.mark("ui.mic-permission-denied")
                failStart(
                    String(localized: "Microphone permission was denied. Please allow access in System Settings → Privacy & Security → Microphone, then try again."),
                    generation: currentGeneration,
                    permissionURL: Self.microphonePrivacyURL
                )
                return
            }
            setStatus(String(localized: "Connecting microphone…"))
            StartupLog.mark("ui.start-operation accent=\(accentCode)")
            let startupStep = RecordingStartupStep(timeoutNanoseconds: 20_000_000_000)
            self.startupStep = startupStep
            do {
                let startError = await startupStep.run(
                    onTimeout: {
                        StartupLog.mark("ui.start-timeout")
                        self.speechManager.stopRecording()
                    },
                    operation: {
                        if accentCode == "auto" {
                            StartupLog.mark("ui.branch:auto")
                            try await self.speechManager.startAutoDetectRecording()
                        } else {
                            StartupLog.mark("ui.branch:fixed \(accentCode)")
                            self.speechManager.switchLanguage(to: accentCode)
                            try await self.speechManager.startRecording()
                        }
                    }
                )
                if self.startupStep === startupStep {
                    self.startupStep = nil
                }
                if let startError { throw startError }
                guard currentGeneration == generation, sessionState.phase == .starting else {
                    speechManager.stopRecording()
                    return
                }
                ensureActiveRecord()
                if let record = activeRecord {
                    speakerEngine?.activate(recordID: record.id)
                }
                sessionState.start()
                startTimer()
                startCheckpointTimer()
                if overlayVisible { subtitleWindow.showWindow() }
                setStatus(String(localized: "Recording · speak now"))
                renderState()
                StartupLog.mark("ui.start-complete")
            } catch {
                StartupLog.mark("ui.start-fail: \(error.localizedDescription)")
                // PSY-02：先把系统错误翻译成"人话 + 可执行下一步"，再显示给用户。
                let humanMessage = RecordingErrorPhraser.humanMessage(for: error)
                    ?? error.localizedDescription
                failStart(humanMessage, generation: currentGeneration)
            }
        }
    }

    private func failStart(_ message: String, generation: Int, permissionURL: URL? = nil) {
        guard generation == self.generation else { return }
        speechManager.stopRecording()
        translationCoordinator.cancelPartials()
        accumulateElapsed()
        subtitleWindow.hideWindow()
        sessionState.failStart(resumable: activeRecord != nil)
        setStatus(message, severity: .error)
        permissionRecoveryURL = permissionURL
        openSettingsButton.isHidden = (permissionURL == nil)
        renderState()
        if let permissionURL { presentPermissionRecovery(message: message, url: permissionURL) }
    }

    /// UX-03：权限类失败不是死路 —— 长文案 + 一键打开系统设置对应隐私面板。
    private func presentPermissionRecovery(message: String, url: URL) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Microphone / speech access is denied")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func openSettingsPressed() {
        if let url = permissionRecoveryURL {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = Self.microphonePrivacyURL { NSWorkspace.shared.open(url) }
    }

    @objc private func pausePressed() {
        guard sessionState.phase == .recording else { return }
        generation += 1
        queueCurrentPartialIfNeeded()
        speechManager.stopRecording()
        speakerEngine?.suspend()
        translationCoordinator.cancelPartials()
        minimumValidPartialRevision = partialRevision + 1
        sessionState.pause()
        stopTimers()
        checkpointActiveRecord()
        setStatus(String(localized: "Recording paused"))
        renderState()
    }

    // UX-02 / PSY-04：所有会终止本次采集的入口共用同一条确认路径，
    // 消除「最显眼的 End Session 零确认、Back 反而要确认」的语义倒挂。
    @objc private func endPressed() { confirmEndAndClose() }

    @objc private func closePressed() {
        // UX-04：收尾保存阶段 Back 不再被禁用。点它 = 不等了，直接返回；
        // 随后的 dismantle 会走 shutDown()，里面已有 checkpoint/finishRecord 兜底保存。
        if sessionState.phase == .ended {
            stopEndingStatusUpdates()
            onClose()
            return
        }
        confirmEndAndClose()
    }

    private func confirmEndAndClose() {
        guard sessionState.phase == .recording
                || sessionState.phase == .starting
                || sessionState.phase == .paused
                || sessionState.phase == .interrupted else {
            finishAndClose()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "End and save this recording?")
        alert.informativeText = String(localized: "The current transcript will be saved before returning.")
        alert.addButton(withTitle: String(localized: "Save and End"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.finishAndClose() }
            }
        } else {
            finishAndClose()
        }
    }

    @objc private func toggleOverlayPressed() {
        overlayVisible.toggle()
        if overlayVisible { subtitleWindow.showWindow() } else { subtitleWindow.hideWindow() }
        overlayButton.title = overlayVisible ? String(localized: "Hide Overlay") : String(localized: "Show Overlay")
    }

    private func finishAndClose() {
        guard sessionState.phase != .ended else { return }
        queueCurrentPartialIfNeeded()
        sessionState.end()
        generation += 1
        speechManager.stopRecording()
        accumulateElapsed()
        stopTimers()
        subtitleWindow.hideWindow()
        renderState()
        // UX-04：结束阶段给出持续的进度感，而不是一行灰字干等最长 10 秒。
        startEndingStatusUpdates()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await RecordingStartupStep.run(
                timeoutNanoseconds: 10_000_000_000,
                onTimeout: { self.translationCoordinator.cancelAll() },
                operation: { await self.translationCoordinator.waitUntilIdle() }
            )
            self.stopEndingStatusUpdates()
            self.setStatus(String(localized: "Saving…"))
            if courseExists, let record = activeRecord {
                historyStore.finishRecord(record, duration: sessionState.elapsed())
                self.setStatus(
                    String(format: String(localized: "Saved · %lld segments"), record.segments.count)
                )
            } else {
                self.setStatus(String(localized: "Saved"))
            }
            // UX-08：多停一拍，让用户看清"存了多少"再返回。
            try? await Task.sleep(for: .milliseconds(900))
            onClose()
        }
    }

    /// UX-04：结束阶段的状态行轮播 —— 还剩几段翻译 → 正在保存 → 已保存（N 段）。
    private func startEndingStatusUpdates() {
        updateEndingStatus()
        endingTimer?.invalidate()
        endingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateEndingStatus() }
        }
    }

    private func updateEndingStatus() {
        guard sessionState.phase == .ended else { return }
        let pending = translationCoordinator.pendingCount
        if pending > 0 {
            setStatus(String(format: String(localized: "Finishing translation (%lld remaining)…"), pending))
        } else {
            setStatus(String(localized: "Finishing translation and saving…"))
        }
    }

    private func stopEndingStatusUpdates() {
        endingTimer?.invalidate()
        endingTimer = nil
    }

    func shutDown() {
        // task-4：先作废在途推理并断开回调，再走下面的 checkpoint 兜底保存，
        // 保证不会出现「checkpoint 之后又改 segmentsData」的未落库窗口。
        speakerEngine?.shutdown()
        speakerEngine?.onLabelsResolved = nil
        generation += 1
        translationGeneration += 1
        translationCoordinator.activateGeneration(translationGeneration)
        let alreadyEnded = sessionState.phase == .ended
        if sessionState.phase == .recording {
            queueCurrentPartialIfNeeded()
            sessionState.interrupt()
        }
        speechManager.stopRecording()
        translationCoordinator.cancelAll()
        if courseExists, let activeRecord {
            if alreadyEnded {
                historyStore.checkpoint(activeRecord, duration: sessionState.elapsed())
            } else {
                historyStore.finishRecord(activeRecord, duration: sessionState.elapsed())
            }
        }
        subtitleWindow.hideWindow()
        timer?.invalidate()
        timer = nil
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        stopEndingStatusUpdates()
        // UX-01：录音页销毁即解锁侧栏（正常路径下 finishAndClose/onClose 会先触发）。
        RecordingActivity.shared.markIdle()
        speechManager.onSegmentRecognized = nil
        speechManager.onRecordingInterrupted = nil
        speechManager.onLanguageModelStatusChanged = nil
        speechManager.onAudioLevelChanged = nil
    }

    /// task-4：装配说话人识别引擎与回写回调。回写经批量 updateSpeakers，
    /// 落库交给现有 checkpoint 机制（30s 检查点 / finishRecord），不做逐条 save。
    private func configureSpeakerEngine() {
        let engine = SpeakerEngine(
            ring: speechManager.speakerRing,
            model: SpeakerEmbeddingModel(bundle: .module)
        )
        engine.onLabelsResolved = { [weak self] updates, currentLabel in
            guard let self else { return }
            if courseExists, let record = activeRecord {
                historyStore.updateSpeakers(updates, in: record)
                rebuildFinalizedText(from: record)
                refreshTranscript()
            }
            updateSpeakerLabel(currentLabel)
        }
        speakerEngine = engine
    }

    /// task-4：控制条显示当前（临时/已解析）说话人。
    private func updateSpeakerLabel(_ name: String?) {
        guard let name, !name.isEmpty else {
            speakerLabel.isHidden = true
            return
        }
        speakerLabel.stringValue = String(format: String(localized: "Speaker: %@"), name)
        speakerLabel.isHidden = false
    }

    private func configureCallbacks() {
        speechManager.onAudioLevelChanged = { [weak self] level in
            guard let self, sessionState.phase == .recording else { return }
            levelIndicator.doubleValue = Double(level)
            if level > 0.03 && partialText.isEmpty {
                setStatus(String(localized: "Sound detected · recognizing…"))
            }
        }
        speechManager.onRecordingInterrupted = { [weak self] in
            guard let self, sessionState.phase != .ended else { return }
            queueCurrentPartialIfNeeded()
            translationCoordinator.cancelPartials()
            minimumValidPartialRevision = partialRevision + 1
            speakerEngine?.suspend()
            sessionState.interrupt()
            stopTimers()
            checkpointActiveRecord()
            setStatus(
                String(localized: "Recording was interrupted. Tap Start to resume."),
                severity: .warning
            )
            renderState()
        }
        speechManager.onLanguageModelStatusChanged = { [weak self] message in
            guard let self, !message.isEmpty else { return }
            setStatus(message)
            startupStep?.kick()
        }
        speechManager.onSegmentRecognized = { [weak self] text, isFinal in
            guard let self, self.sessionState.phase == .recording else { return }
            self.ensureActiveRecord()
            self.partialRevision += 1
            let eventRevision = self.partialRevision
            if isFinal {
                self.enqueueFinal(text, revision: eventRevision)
            } else {
                self.partialText = text
                self.partialTranslation = ""
                self.refreshTranscript()
                let cue = SubtitleCueBuilder.cue(from: text, maximumWords: self.subtitleMaximumWords)
                self.submitPartialTranslation(text, cue: cue, revision: eventRevision)
            }
        }
    }

    private func enqueueFinal(_ text: String, revision: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, courseExists else { return }
        lastEnqueuedFinalRevision = revision
        ensureActiveRecord()
        let sentence = Self.ensureEndingPunctuation(trimmed)
        let cue = SubtitleCueBuilder.cue(from: sentence, maximumWords: subtitleMaximumWords)
        // task-4：先挂当前（临时）说话人标签，取窗解析后由引擎回写精确标签。
        let segment = TranscriptSegment(original: sentence, translated: "", speaker: speakerEngine?.currentLabel)
        if let activeRecord {
            historyStore.addSegmentIfNew(segment, to: activeRecord)
            rebuildFinalizedText(from: activeRecord)
            speakerEngine?.segmentsCommitted([segment.id])
        }
        if partialText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            partialText = ""
            partialTranslation = ""
        }
        refreshTranscript()
        translationCoordinator.submit(.init(
            kind: .final,
            text: sentence,
            cue: cue,
            revision: revision,
            generation: translationGeneration,
            segmentID: segment.id,
            completion: { [weak self] response in self?.handleTranslation(response) }
        ))
    }

    private func submitPartialTranslation(_ text: String, cue: String, revision: Int) {
        translationCoordinator.submit(.init(
            kind: .partial,
            text: text,
            cue: cue,
            revision: revision,
            generation: translationGeneration,
            completion: { [weak self] response in self?.handleTranslation(response) }
        ))
    }

    private func handleTranslation(_ response: LiveTranslationCoordinator.Response) {
        guard response.request.generation == translationGeneration else { return }
        if response.request.kind == .partial {
            guard sessionState.phase == .recording,
                  response.request.revision >= minimumValidPartialRevision else { return }
        }
        if !response.succeeded, response.request.kind == .partial {
            setStatus(
                String(localized: "Translation unavailable · transcript is still being saved"),
                severity: .warning
            )
            return
        }
        if response.succeeded, overlayVisible {
            // task-4：字幕带说话人前缀（final 用段落里的精确标签，partial 用当前标签）。
            let speaker: String?
            if response.request.kind == .final,
               let segmentID = response.request.segmentID,
               let record = activeRecord {
                speaker = record.segments.first(where: { $0.id == segmentID })?.speaker
            } else {
                speaker = speakerEngine?.currentLabel
            }
            subtitleWindow.showStableCue(
                original: response.request.text,
                translated: response.translatedText,
                speaker: speaker,
                // task-10：会话上下文（本记录人员映射）传入字幕悬浮窗；
                // 新录记录 speakerNames=nil → [:] 零解析开销。
                aliases: activeRecord?.aliasMap ?? [:]
            )
        }

        switch response.request.kind {
        case .partial:
            if partialText == response.request.text {
                partialTranslation = response.translatedText
                refreshTranscript()
            }
        case .final:
            if courseExists, let record = activeRecord, let segmentID = response.request.segmentID {
                historyStore.updateTranslation(for: segmentID, to: response.translatedText, in: record)
                rebuildFinalizedText(from: record)
            }
            if partialText.trimmingCharacters(in: .whitespacesAndNewlines) == response.request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                || partialRevision == response.request.revision {
                partialText = ""
                partialTranslation = ""
            }
            refreshTranscript()
            if sessionState.phase == .paused || sessionState.phase == .interrupted {
                checkpointActiveRecord()
            }
        }
        if sessionState.phase == .recording {
            if response.succeeded {
                setStatus(String(localized: "Recording · live translation"))
            } else {
                setStatus(
                    String(localized: "Translation unavailable · transcript saved without translation"),
                    severity: .warning
                )
            }
        } else if sessionState.phase == .paused {
            setStatus(String(localized: "Recording paused"))
        }
    }

    private func queueCurrentPartialIfNeeded() {
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, partialRevision != lastEnqueuedFinalRevision else { return }
        partialRevision += 1
        enqueueFinal(text, revision: partialRevision)
    }

    private static func ensureEndingPunctuation(_ text: String) -> String {
        let result = fixInternalPunctuation(text)
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return result }
        if ".!?。！？…".contains(last) { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("what") || lower.hasPrefix("how") || lower.hasPrefix("why")
            || lower.hasPrefix("where") || lower.hasPrefix("when") || lower.hasPrefix("who")
            || lower.hasPrefix("can ") || lower.hasPrefix("could ") || lower.hasPrefix("would")
            || lower.hasPrefix("is ") || lower.hasPrefix("are ") || lower.hasPrefix("do ")
            || lower.hasPrefix("does ") || lower.hasPrefix("did ") {
            return trimmed + "?"
        }
        return trimmed + "."
    }

    private static func fixInternalPunctuation(_ text: String) -> String {
        let conjunctions = ["and ", "but ", "so ", "or ", "yet ", "because ", "although ",
                            "while ", "when ", "if ", "then ", "therefore ", "however ",
                            "moreover ", "furthermore ", "nevertheless ", "also "]
        var result = text
        for conj in conjunctions {
            let pattern = ", " + conj
            while let range = result.range(of: pattern, options: .caseInsensitive) {
                let afterConj = result[range.upperBound...]
                let words = afterConj.prefix(while: { !$0.isNewline && $0 != "." && $0 != "!" && $0 != "?" })
                if words.split(separator: " ").count >= 2 {
                    result.replaceSubrange(range.lowerBound..<range.upperBound, with: ". " + conj)
                } else {
                    break
                }
            }
        }
        return result
    }

    /// VIS-02：原文 13pt / secondary，译文 15pt / label —— 一眼能分清哪句是译文。
    private static let originalTextAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    private static let translatedTextAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor.labelColor,
    ]

    private func refreshTranscript() {
        guard let storage = transcriptView.textStorage else { return }
        let full = finalizedText

        if !hasRenderedTranscript || full != renderedFinalizedText {
            storage.setAttributedString(finalizedAttributed)
            renderedFinalizedText = full
            liveTranscriptRange = nil
            hasRenderedTranscript = true
        } else if let range = liveTranscriptRange, range.location + range.length <= storage.length {
            storage.deleteCharacters(in: range)
            liveTranscriptRange = nil
        }

        if !partialText.isEmpty || !partialTranslation.isEmpty {
            let prefix = storage.length > 0 ? "\n\n" : ""
            let start = storage.length
            let live = NSMutableAttributedString(string: prefix)
            // task-4：实时 partial 同样带当前说话人前缀（共用 SpeakerLabels helper）。
            // task-10：带本记录人员映射（nickname 命中时显示「王教授: 」）。
            let liveOriginal = SpeakerLabels.prefix(
                speakerEngine?.currentLabel,
                aliases: activeRecord?.aliasMap ?? [:]
            ) + partialText
            live.append(NSAttributedString(string: liveOriginal, attributes: Self.originalTextAttributes))
            if !partialTranslation.isEmpty {
                live.append(NSAttributedString(
                    string: "\n" + partialTranslation,
                    attributes: Self.translatedTextAttributes
                ))
            }
            storage.append(live)
            liveTranscriptRange = NSRange(location: start, length: live.length)
        }

        if SubtitleDisplayConfiguration().autoScroll { transcriptView.scrollToEndOfDocument(nil) }
    }

    private func rebuildFinalizedText(from record: TranscriptRecord) {
        let result = NSMutableAttributedString()
        // task-10：人员映射取一次复用（解析 JSON 每段一次太浪费）。
        let aliases = record.aliasMap
        for (index, segment) in record.segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(
                string: SpeakerLabels.prefix(segment.speaker, aliases: aliases) + segment.original,
                attributes: Self.originalTextAttributes
            ))
            let translation = segment.translated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !translation.isEmpty {
                result.append(NSAttributedString(string: "\n"))
                result.append(NSAttributedString(
                    string: translation,
                    attributes: Self.translatedTextAttributes
                ))
            }
        }
        finalizedAttributed = result
        finalizedText = result.string
    }

    /// VIS-01：状态行视觉分级 —— 普通 secondary、警告 orange + ⚠、错误 red + ⛔
    /// 且允许换行，避免权限失败这种长文案被 byTruncatingTail 吃掉。
    private enum StatusSeverity { case normal, warning, error }

    private func setStatus(_ message: String, severity: StatusSeverity = .normal) {
        switch severity {
        case .normal:
            statusLabel.stringValue = message
            statusLabel.textColor = .secondaryLabelColor
            // VIS-01 / PSY-05：模型下载进度这类长文案给两行，避免
            // "… (45%)" 的尾巴被 byTruncatingTail 在一行里吃掉。
            statusLabel.lineBreakMode = .byTruncatingTail
            statusLabel.maximumNumberOfLines = 2
        case .warning:
            statusLabel.stringValue = "⚠︎ " + message
            statusLabel.textColor = .systemOrange
            statusLabel.lineBreakMode = .byWordWrapping
            statusLabel.maximumNumberOfLines = 2
        case .error:
            statusLabel.stringValue = "⛔︎ " + message
            statusLabel.textColor = .systemRed
            statusLabel.lineBreakMode = .byWordWrapping
            statusLabel.maximumNumberOfLines = 3
        }
        statusLabel.invalidateIntrinsicContentSize()
    }

    private func renderState() {
        let phase = sessionState.phase
        startButton.isEnabled = phase == .idle || phase == .paused || phase == .interrupted
        startButton.title = (phase == .paused || phase == .interrupted) ? String(localized: "Resume") : String(localized: "Start")
        pauseButton.isEnabled = phase == .recording
        endButton.isEnabled = phase == .recording || phase == .paused || phase == .starting || phase == .interrupted
        // UX-04：结束收尾（.ended）期间 Back 保持可用，作为等不及时的兜底保存出口。
        closeButton.isEnabled = true
        overlayButton.isEnabled = phase != .ended
        syncRecordingActivity()
    }

    /// UX-01：把当前录音状态同步给侧栏。HomeView 只读这个标志，
    /// 不会把任何条件视图塞进本 representable —— 那会踩到 macOS 26 布局死循环。
    private func syncRecordingActivity() {
        let phase = sessionState.phase
        // .ended 也要锁：收尾保存还没落地，此时 dismantle 会和保存赛跑。
        let active = phase == .starting || phase == .recording || phase == .paused
            || phase == .interrupted || phase == .ended
        if active {
            RecordingActivity.shared.markActive()
        } else {
            RecordingActivity.shared.markIdle()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshElapsed() }
        }
        refreshElapsed()
    }

    private func accumulateElapsed() {
        timer?.invalidate()
        timer = nil
        levelIndicator.doubleValue = 0
        refreshElapsed()
    }

    private func refreshElapsed() {
        // VIS-09：统一成 h:mm:ss（超 1 小时的课是常态，75:33 这种分钟数不成立）。
        elapsedLabel.stringValue = Self.formatDuration(sessionState.elapsed())
    }

    /// VIS-09：与导出/历史列表使用完全相同的计时格式。
    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private var subtitleMaximumWords: Int {
        SubtitleDisplayConfiguration().maximumWords
    }

    private func startCheckpointTimer() {
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpointActiveRecord() }
        }
    }

    private func stopTimers() {
        timer?.invalidate()
        timer = nil
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        levelIndicator.doubleValue = 0
        refreshElapsed()
    }

    private func checkpointActiveRecord() {
        guard courseExists, let activeRecord else { return }
        historyStore.checkpoint(activeRecord, duration: sessionState.elapsed())
    }

    private func ensureActiveRecord() {
        guard activeRecord == nil, courseExists else { return }
        activeRecord = historyStore.startNewRecord(in: course)
        translationGeneration += 1
        translationCoordinator.activateGeneration(translationGeneration)
        partialText = ""
        partialTranslation = ""
        subtitleWindow.clearAll()
    }
}
