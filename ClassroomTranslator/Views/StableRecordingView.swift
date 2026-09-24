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
    private let historyStore: HistoryStore
    private let translationManager: TranslationManager
    private let onClose: () -> Void
    private let speechManager = SpeechManager()
    private let subtitleWindow = SubtitleWindowController()

    private let transcriptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "00:00")
    private let levelIndicator = NSProgressIndicator()
    private let startButton = NSButton(title: String(localized: "Start"), target: nil, action: nil)
    private let pauseButton = NSButton(title: String(localized: "Pause"), target: nil, action: nil)
    private let endButton = NSButton(title: String(localized: "End Session"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "Back"), target: nil, action: nil)
    private let overlayButton = NSButton(title: String(localized: "Hide Overlay"), target: nil, action: nil)

    private var sessionState = RecordingSessionState()
    private var activeRecord: TranscriptRecord?
    private var finalizedText = ""
    private var renderedFinalizedText = ""
    private var liveTranscriptRange: NSRange?
    private var hasRenderedTranscript = false
    private var partialText = ""
    private var partialTranslation = ""
    private var translationCoordinator: LiveTranslationCoordinator!
    private var partialRevision = 0
    private var generation = 0
    private var timer: Timer?
    private var checkpointTimer: Timer?
    private var overlayVisible = true
    private var lastEnqueuedFinalRevision = -1
    private var translationGeneration = 0
    private var minimumValidPartialRevision = 0

    init(course: Course, historyStore: HistoryStore, translationManager: TranslationManager, onClose: @escaping () -> Void) {
        self.course = course
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

        let header = NSStackView(views: [closeButton, title, accent])
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
        transcriptView.string = String(localized: "Ready to Listen")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = transcriptView
        transcriptView.frame = NSRect(x: 0, y: 0, width: 640, height: 240)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        levelIndicator.style = .bar
        levelIndicator.minValue = 0
        levelIndicator.maxValue = 1
        levelIndicator.doubleValue = 0
        levelIndicator.toolTip = String(localized: "Microphone input level")
        levelIndicator.widthAnchor.constraint(equalToConstant: 96).isActive = true

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

        let controls = NSStackView(views: [statusLabel, levelIndicator, elapsedLabel, overlayButton, startButton, pauseButton, endButton])
        controls.orientation = .horizontal
        controls.spacing = 12
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
        configureCallbacks()
        renderState()
    }

    @objc private func startPressed() {
        guard sessionState.phase == .idle || sessionState.phase == .paused || sessionState.phase == .interrupted else { return }
        beginRecording()
    }

    private func beginRecording() {
        generation += 1
        let currentGeneration = generation
        sessionState.beginStarting()
        speechManager.configureContext(courseName: course.name)
        statusLabel.stringValue = String(localized: "Requesting speech recognition permission…")
        renderState()

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await speechManager.requestSpeechPermission() else {
                failStart(String(localized: "Speech recognition permission was denied."), generation: currentGeneration)
                return
            }
            statusLabel.stringValue = String(localized: "Requesting microphone permission…")
            guard await speechManager.requestMicPermission() else {
                failStart(String(localized: "Microphone permission was denied."), generation: currentGeneration)
                return
            }
            statusLabel.stringValue = String(localized: "Connecting microphone…")
            do {
                let startError = await RecordingStartupStep.run(
                    timeoutNanoseconds: 20_000_000_000,
                    onTimeout: { self.speechManager.stopRecording() },
                    operation: {
                        if self.course.accentCode == "auto" {
                            try await self.speechManager.startAutoDetectRecording()
                        } else {
                            self.speechManager.switchLanguage(to: self.course.accentCode)
                            try await self.speechManager.startRecording()
                        }
                    }
                )
                if let startError { throw startError }
                guard currentGeneration == generation, sessionState.phase == .starting else {
                    speechManager.stopRecording()
                    return
                }
                ensureActiveRecord()
                sessionState.start()
                startTimer()
                startCheckpointTimer()
                if overlayVisible { subtitleWindow.showWindow() }
                statusLabel.stringValue = String(localized: "Recording · speak now")
                renderState()
            } catch {
                failStart(error.localizedDescription, generation: currentGeneration)
            }
        }
    }

    private func failStart(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        speechManager.stopRecording()
        translationCoordinator.cancelPartials()
        accumulateElapsed()
        subtitleWindow.hideWindow()
        sessionState.failStart(resumable: activeRecord != nil)
        statusLabel.stringValue = message
        renderState()
    }

    @objc private func pausePressed() {
        guard sessionState.phase == .recording else { return }
        generation += 1
        queueCurrentPartialIfNeeded()
        speechManager.stopRecording()
        translationCoordinator.cancelPartials()
        minimumValidPartialRevision = partialRevision + 1
        sessionState.pause()
        stopTimers()
        checkpointActiveRecord()
        statusLabel.stringValue = String(localized: "Recording paused")
        renderState()
    }

    @objc private func endPressed() {
        finishAndClose()
    }

    @objc private func closePressed() {
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
        statusLabel.stringValue = String(localized: "Finishing translation and saving…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await RecordingStartupStep.run(
                timeoutNanoseconds: 10_000_000_000,
                onTimeout: { self.translationCoordinator.cancelAll() },
                operation: { await self.translationCoordinator.waitUntilIdle() }
            )
            if let record = activeRecord {
                historyStore.finishRecord(record, duration: sessionState.elapsed())
            }
            statusLabel.stringValue = String(localized: "Saved")
            try? await Task.sleep(for: .milliseconds(450))
            onClose()
        }
    }

    func shutDown() {
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
        if let activeRecord {
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
        speechManager.onSegmentRecognized = nil
        speechManager.onRecordingInterrupted = nil
        speechManager.onLanguageModelStatusChanged = nil
        speechManager.onAudioLevelChanged = nil
    }

    private func configureCallbacks() {
        speechManager.onAudioLevelChanged = { [weak self] level in
            guard let self, sessionState.phase == .recording else { return }
            levelIndicator.doubleValue = Double(level)
            if level > 0.03 && partialText.isEmpty {
                statusLabel.stringValue = String(localized: "Sound detected · recognizing…")
            }
        }
        speechManager.onRecordingInterrupted = { [weak self] in
            guard let self, sessionState.phase != .ended else { return }
            queueCurrentPartialIfNeeded()
            translationCoordinator.cancelPartials()
            minimumValidPartialRevision = partialRevision + 1
            sessionState.interrupt()
            stopTimers()
            checkpointActiveRecord()
            statusLabel.stringValue = String(localized: "Recording was interrupted. Tap Start to resume.")
            renderState()
        }
        speechManager.onLanguageModelStatusChanged = { [weak self] message in
            guard let self, !message.isEmpty else { return }
            statusLabel.stringValue = message
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
        guard !trimmed.isEmpty else { return }
        lastEnqueuedFinalRevision = revision
        ensureActiveRecord()
        let sentence = Self.ensureEndingPunctuation(trimmed)
        let cue = SubtitleCueBuilder.cue(from: sentence, maximumWords: subtitleMaximumWords)
        let segment = TranscriptSegment(original: sentence, translated: "")
        if let activeRecord {
            historyStore.addSegmentIfNew(segment, to: activeRecord)
            rebuildFinalizedText(from: activeRecord)
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
            statusLabel.stringValue = String(localized: "Translation unavailable · transcript is still being saved")
            return
        }
        if response.succeeded, overlayVisible {
            subtitleWindow.showStableCue(original: response.request.text, translated: response.translatedText)
        }

        switch response.request.kind {
        case .partial:
            if partialText == response.request.text {
                partialTranslation = response.translatedText
                refreshTranscript()
            }
        case .final:
            if let record = activeRecord, let segmentID = response.request.segmentID {
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
            statusLabel.stringValue = response.succeeded
                ? String(localized: "Recording · live translation")
                : String(localized: "Translation unavailable · transcript saved without translation")
        } else if sessionState.phase == .paused {
            statusLabel.stringValue = String(localized: "Recording paused")
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

    private func refreshTranscript() {
        let full = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = partialTranslation.isEmpty ? partialText : "\(partialText)\n\(partialTranslation)"
        guard let storage = transcriptView.textStorage else { return }

        if !hasRenderedTranscript || full != renderedFinalizedText {
            storage.setAttributedString(NSAttributedString(string: full))
            renderedFinalizedText = full
            liveTranscriptRange = nil
            hasRenderedTranscript = true
        } else if let range = liveTranscriptRange, range.location + range.length <= storage.length {
            storage.deleteCharacters(in: range)
            liveTranscriptRange = nil
        }

        if !live.isEmpty {
            let prefix = storage.length > 0 ? "\n\n" : ""
            let start = storage.length
            let value = prefix + live
            storage.append(NSAttributedString(string: value))
            liveTranscriptRange = NSRange(location: start, length: (value as NSString).length)
        }

        if SubtitleDisplayConfiguration().autoScroll { transcriptView.scrollToEndOfDocument(nil) }
    }

    private func rebuildFinalizedText(from record: TranscriptRecord) {
        finalizedText = record.segments.map { segment in
            let translation = segment.translated.trimmingCharacters(in: .whitespacesAndNewlines)
            return translation.isEmpty ? segment.original : "\(segment.original)\n\(translation)"
        }.joined(separator: "\n\n")
    }

    private func renderState() {
        let phase = sessionState.phase
        startButton.isEnabled = phase == .idle || phase == .paused || phase == .interrupted
        startButton.title = (phase == .paused || phase == .interrupted) ? String(localized: "Resume") : String(localized: "Start")
        pauseButton.isEnabled = phase == .recording
        endButton.isEnabled = phase == .recording || phase == .paused || phase == .starting || phase == .interrupted
        closeButton.isEnabled = phase != .ended
        overlayButton.isEnabled = phase != .ended
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
        let total = sessionState.elapsed()
        elapsedLabel.stringValue = String(format: "%02d:%02d", Int(total) / 60, Int(total) % 60)
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
        guard let activeRecord else { return }
        historyStore.checkpoint(activeRecord, duration: sessionState.elapsed())
    }

    private func ensureActiveRecord() {
        guard activeRecord == nil else { return }
        activeRecord = historyStore.startNewRecord(in: course)
        translationGeneration += 1
        translationCoordinator.activateGeneration(translationGeneration)
        partialText = ""
        partialTranslation = ""
        subtitleWindow.clearAll()
    }
}
