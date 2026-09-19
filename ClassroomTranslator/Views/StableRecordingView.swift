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
    private enum State { case idle, starting, recording, paused, ended }

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

    private var state: State = .idle
    private var finalizedText = ""
    private var lastCommittedEnglish = ""
    private var partialText = ""
    private var partialTranslation = ""
    private var partialTranslationTask: Task<Void, Never>?
    private var finalTranslationTasks: [Task<Void, Never>] = []
    private var partialRevision = 0
    private var generation = 0
    private var timer: Timer?
    private var startedAt: Date?
    private var elapsedBeforePause: TimeInterval = 0

    init(course: Course, historyStore: HistoryStore, translationManager: TranslationManager, onClose: @escaping () -> Void) {
        self.course = course
        self.historyStore = historyStore
        self.translationManager = translationManager
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.bezelStyle = .rounded

        let title = NSTextField(labelWithString: course.name)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let accent = NSTextField(labelWithString: course.accentName)
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

        let controls = NSStackView(views: [statusLabel, levelIndicator, elapsedLabel, startButton, pauseButton, endButton])
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
        guard state == .idle || state == .paused else { return }
        beginRecording()
    }

    private func beginRecording() {
        generation += 1
        let currentGeneration = generation
        state = .starting
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
                if course.accentCode == "auto" {
                    try await speechManager.startAutoDetectRecording()
                } else {
                    speechManager.switchLanguage(to: course.accentCode)
                    try await speechManager.startRecording()
                }
                guard currentGeneration == generation, state == .starting else {
                    speechManager.stopRecording()
                    return
                }
                if historyStore.currentRecord == nil {
                    historyStore.startNewRecord(in: course)
                }
                state = .recording
                startedAt = Date()
                lastCommittedEnglish = ""
                startTimer()
                subtitleWindow.clearAll()
                subtitleWindow.showWindow()
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
        accumulateElapsed()
        subtitleWindow.hideWindow()
        state = .idle
        statusLabel.stringValue = message
        renderState()
    }

    @objc private func pausePressed() {
        guard state == .recording else { return }
        generation += 1
        speechManager.stopRecording()
        state = .paused
        statusLabel.stringValue = String(localized: "Recording paused")
        renderState()
    }

    @objc private func endPressed() {
        finishAndClose()
    }

    @objc private func closePressed() {
        finishAndClose()
    }

    private func finishAndClose() {
        guard state != .ended else { return }
        state = .ended
        generation += 1
        speechManager.stopRecording()
        accumulateElapsed()
        lastCommittedEnglish = ""
        subtitleWindow.hideWindow()
        renderState()
        statusLabel.stringValue = String(localized: "Finishing translation and saving…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for task in finalTranslationTasks { await task.value }
            let remainder = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                let translated = await translationManager.translate(remainder)
                historyStore.addSegmentIfNew(TranscriptSegment(original: remainder, translated: translated))
                finalizedText += "\n\n\(remainder)\n\(translated)"
                partialText = ""
                partialTranslation = ""
                refreshTranscript()
            }
            historyStore.stopCurrentRecord()
            statusLabel.stringValue = String(localized: "Saved")
            try? await Task.sleep(for: .milliseconds(450))
            onClose()
        }
    }

    func shutDown() {
        generation += 1
        speechManager.stopRecording()
        partialTranslationTask?.cancel()
        partialTranslationTask = nil
        lastCommittedEnglish = ""
        subtitleWindow.hideWindow()
        timer?.invalidate()
        timer = nil
        speechManager.onSegmentRecognized = nil
        speechManager.onRecordingInterrupted = nil
        speechManager.onLanguageModelStatusChanged = nil
        speechManager.onAudioLevelChanged = nil
    }

    private func configureCallbacks() {
        speechManager.onAudioLevelChanged = { [weak self] level in
            guard let self, state == .recording else { return }
            levelIndicator.doubleValue = Double(level)
            if level > 0.03 && partialText.isEmpty {
                statusLabel.stringValue = String(localized: "Sound detected · recognizing…")
            }
        }
        speechManager.onRecordingInterrupted = { [weak self] in
            guard let self, state != .ended else { return }
            state = .idle
            statusLabel.stringValue = String(localized: "Recording was interrupted. Tap Start to resume.")
            renderState()
        }
        speechManager.onLanguageModelStatusChanged = { [weak self] message in
            guard let self, !message.isEmpty else { return }
            statusLabel.stringValue = message
        }
        speechManager.onSegmentRecognized = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                partialRevision += 1
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        self.partialText = ""
                        self.partialTranslation = ""
                        self.refreshTranscript()
                        return
                    }
                    let sentence = Self.ensureEndingPunctuation(trimmed)
                    let translated = await self.translationManager.translate(sentence)
                    self.finalizedText += "\n\n\(sentence)\n\(translated)"
                    self.lastCommittedEnglish = sentence
                    self.historyStore.addSegmentIfNew(TranscriptSegment(original: sentence, translated: translated))
                    self.subtitleWindow.appendSegment(original: sentence, translated: translated)
                    self.partialText = ""
                    self.partialTranslation = ""
                    self.refreshTranscript()
                }
                finalTranslationTasks.append(task)
            } else {
                self.partialText = text
                self.partialTranslation = ""
                self.refreshTranscript()
                self.subtitleWindow.updateCurrentText(original: text, translated: "")
                self.translatePartial(text)
            }
        }
    }

    private static func ensureEndingPunctuation(_ text: String) -> String {
        var result = fixInternalPunctuation(text)
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
        transcriptView.string = live.isEmpty ? full : "\(full)\(full.isEmpty ? "" : "\n\n")\(live)"
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func removeLastFinalizedSegment() {
        if let range = finalizedText.range(of: "\n\n", options: .backwards) {
            finalizedText = String(finalizedText[..<range.lowerBound])
        } else {
            finalizedText = ""
        }
    }

    private static let sentenceEndingPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ")", "]", "」", "』", "\"", "'", "\u{201D}", "\u{2019}"]

    private static func hasSentenceEnding(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        return sentenceEndingPunctuation.contains(last)
    }

    private func translatePartial(_ text: String) {
        partialRevision += 1
        let revision = partialRevision
        partialTranslationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, revision == partialRevision else { return }
            let translated = await translationManager.translate(text)
            guard !Task.isCancelled, revision == partialRevision, partialText == text, state == .recording else { return }
            partialTranslation = translated
            refreshTranscript()
            subtitleWindow.updateCurrentText(original: text, translated: translated)
            statusLabel.stringValue = String(localized: "Recording · live translation")
        }
    }

    private func renderState() {
        startButton.isEnabled = state == .idle || state == .paused
        startButton.title = state == .paused ? String(localized: "Resume") : String(localized: "Start")
        pauseButton.isEnabled = state == .recording
        endButton.isEnabled = state == .recording || state == .paused || state == .starting
        closeButton.isEnabled = state != .ended
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshElapsed() }
        }
        refreshElapsed()
    }

    private func accumulateElapsed() {
        if let startedAt { elapsedBeforePause += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        timer?.invalidate()
        timer = nil
        levelIndicator.doubleValue = 0
        refreshElapsed()
    }

    private func refreshElapsed() {
        let total = elapsedBeforePause + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)
        elapsedLabel.stringValue = String(format: "%02d:%02d", Int(total) / 60, Int(total) % 60)
    }
}
