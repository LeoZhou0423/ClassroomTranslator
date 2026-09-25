import SwiftUI
import AppKit

@MainActor
final class SubtitleWindowController: NSWindowController {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 180))
    private var overlayWasVisible = false
    private var latestOriginal = ""
    private var latestTranslation = ""

    convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .resizable],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("SubtitleOverlay")
        window.setFrameAutosaveName("SubtitleOverlayFrame")

        self.init(window: window)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        window.contentView = scrollView

        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillEnterFullScreen(_:)), name: NSWindow.willEnterFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowDidExitFullScreen(_:)), name: NSWindow.didExitFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)

        applyDisplaySettings()
        window.center()
    }

    @objc private func settingsDidChange(_ note: Notification) {
        if Thread.isMainThread {
            applyDisplaySettings()
            renderLatestCue()
        } else {
            Task { @MainActor [weak self] in
                self?.applyDisplaySettings()
                self?.renderLatestCue()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func mainWindowWillEnterFullScreen(_ note: Notification) {
        guard let entering = note.object as? NSWindow, entering != window else { return }
        overlayWasVisible = window?.isVisible == true
        hideWindow()
    }

    @objc private func mainWindowDidExitFullScreen(_ note: Notification) {
        guard let exiting = note.object as? NSWindow, exiting != window else { return }
        if overlayWasVisible {
            overlayWasVisible = false
            showWindow()
        }
    }

    /// Replaces the entire overlay in one text-storage operation so source and
    /// translation can never briefly belong to different recognition revisions.
    func showStableCue(original: String, translated: String) {
        guard !original.isEmpty || !translated.isEmpty else { return }
        latestOriginal = original
        latestTranslation = translated
        renderLatestCue()
    }

    private func renderLatestCue() {
        let configuration = SubtitleDisplayConfiguration()
        let fontSize = configuration.fontSize
        let showOriginal = configuration.showOriginal
        let originalCue = SubtitleCueBuilder.cue(
            from: latestOriginal,
            maximumWords: configuration.maximumWords,
            maximumCharacters: 52
        )
        let translatedCue = SubtitleCueBuilder.cue(
            from: latestTranslation,
            maximumWords: 10,
            maximumCharacters: 32
        )
        let value = NSMutableAttributedString()
        if showOriginal, !originalCue.isEmpty {
            value.append(NSAttributedString(string: originalCue, attributes: subtitleAttrs(fontSize: fontSize - 4, color: .systemYellow)))
        }
        if !translatedCue.isEmpty {
            let prefix = value.length > 0 ? "\n" : ""
            value.append(NSAttributedString(string: prefix + translatedCue, attributes: subtitleAttrs(fontSize: fontSize, color: .white)))
        }
        textView.textStorage?.setAttributedString(value)
        scrollToBottom()
    }

    func clearAll() {
        textView.string = ""
        latestOriginal = ""
        latestTranslation = ""
    }

    func showWindow() {
        window?.orderFront(nil)
    }

    func hideWindow() {
        window?.orderOut(nil)
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [textView] in
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func applyDisplaySettings() {
        window?.backgroundColor = NSColor.black.withAlphaComponent(SubtitleDisplayConfiguration().opacity)
    }

    private func subtitleAttrs(fontSize: Double, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
    }
}
