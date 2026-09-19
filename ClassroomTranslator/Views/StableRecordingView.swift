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

    private let transcriptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: String(localized: "Start"), target: nil, action: nil)
    private let pauseButton = NSButton(title: String(localized: "Pause"), target: nil, action: nil)
    private let endButton = NSButton(title: String(localized: "End Session"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "Back"), target: nil, action: nil)

    private var state: State = .idle
    private var finalizedText = ""
    private var partialText = ""
    private var generation = 0

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
        transcriptView.font = .systemFont(ofSize: 15)
        transcriptView.textContainerInset = NSSize(width: 12, height: 12)
        transcriptView.string = String(localized: "Ready to Listen")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = transcriptView

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

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

        let controls = NSStackView(views: [statusLabel, startButton, pauseButton, endButton])
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
        statusLabel.stringValue = String(localized: "Starting recording…")
        renderState()

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await speechManager.requestSpeechPermission() else {
                failStart(String(localized: "Speech recognition permission was denied."), generation: currentGeneration)
                return
            }
            guard await speechManager.requestMicPermission() else {
                failStart(String(localized: "Microphone permission was denied."), generation: currentGeneration)
                return
            }
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
                statusLabel.stringValue = String(localized: "Recording")
                renderState()
            } catch {
                failStart(error.localizedDescription, generation: currentGeneration)
            }
        }
    }

    private func failStart(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        speechManager.stopRecording()
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
        historyStore.stopCurrentRecord()
        onClose()
    }

    func shutDown() {
        generation += 1
        speechManager.stopRecording()
        speechManager.onSegmentRecognized = nil
        speechManager.onRecordingInterrupted = nil
        speechManager.onLanguageModelStatusChanged = nil
    }

    private func configureCallbacks() {
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
                Task { @MainActor in
                    let punctuated = await PunctuationService.punctuate(text)
                    let translated = await translationManager.translate(punctuated)
                    finalizedText += "\n\n\(punctuated)\n\(translated)"
                    partialText = ""
                    historyStore.addSegmentIfNew(TranscriptSegment(original: punctuated, translated: translated))
                    refreshTranscript()
                }
            } else {
                partialText = text
                refreshTranscript()
            }
        }
    }

    private func refreshTranscript() {
        let full = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptView.string = partialText.isEmpty ? full : "\(full)\(full.isEmpty ? "" : "\n\n")\(partialText)"
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func renderState() {
        startButton.isEnabled = state == .idle || state == .paused
        startButton.title = state == .paused ? String(localized: "Resume") : String(localized: "Start")
        pauseButton.isEnabled = state == .recording
        endButton.isEnabled = state == .recording || state == .paused || state == .starting
        closeButton.isEnabled = state != .ended
    }
}
