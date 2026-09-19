import SwiftUI
import AppKit

@MainActor
final class SubtitleWindowController: NSWindowController {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 180))
    private var overlayWasVisible = false
    private var currentPartialRange: NSRange?

    convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
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

        window.center()
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

    func appendSegment(original: String, translated: String) {
        guard !original.isEmpty || !translated.isEmpty else { return }
        let fontSize = UserDefaults.standard.double(forKey: "fontSize").clamped(to: 12...36, default: 20)

        // 移除正在显示的 partial（如有）
        removeCurrentPartial()

        let attrString = NSMutableAttributedString()
        if !textView.string.isEmpty {
            attrString.append(NSAttributedString(string: "\n\n", attributes: [.foregroundColor: NSColor.clear]))
        }
        attrString.append(NSAttributedString(string: original, attributes: subtitleAttrs(fontSize: fontSize - 4, color: .systemYellow)))
        if !translated.isEmpty {
            attrString.append(NSAttributedString(string: "\n" + translated, attributes: subtitleAttrs(fontSize: fontSize, color: .white)))
        }
        textView.textStorage?.append(attrString)
        currentPartialRange = nil
        scrollToBottom()
    }

    func updateCurrentText(_ text: String) {
        guard !text.isEmpty else {
            removeCurrentPartial()
            return
        }
        let fontSize = UserDefaults.standard.double(forKey: "fontSize").clamped(to: 12...36, default: 20)
        let partialAttr = NSAttributedString(string: text, attributes: subtitleAttrs(fontSize: fontSize - 4, color: .systemYellow))

        if let range = currentPartialRange, let storage = textView.textStorage,
           range.location + range.length <= storage.length {
            storage.replaceCharacters(in: range, with: partialAttr)
            currentPartialRange = NSRange(location: range.location, length: partialAttr.length)
        } else {
            if let storage = textView.textStorage, storage.length > 0 {
                storage.append(NSAttributedString(string: "\n", attributes: [.foregroundColor: NSColor.clear]))
            }
            let startLocation = textView.textStorage?.length ?? 0
            textView.textStorage?.append(partialAttr)
            currentPartialRange = NSRange(location: startLocation, length: partialAttr.length)
        }
        scrollToBottom()
    }

    func updateCurrentText(original: String, translated: String) {
        let combined = translated.isEmpty ? original : original + "\n" + translated
        updateCurrentText(combined)
    }

    private func removeCurrentPartial() {
        guard let range = currentPartialRange, let storage = textView.textStorage,
              range.location + range.length <= storage.length else {
            currentPartialRange = nil
            return
        }
        // 也删除 partial 前的分隔换行符
        var removeRange = range
        if range.location > 0 {
            let before = NSRange(location: range.location - 1, length: 1)
            if storage.attributedSubstring(from: before).string == "\n" {
                removeRange = NSRange(location: range.location - 1, length: range.length + 1)
            }
        }
        storage.deleteCharacters(in: removeRange)
        currentPartialRange = nil
    }

    func clearAll() {
        textView.string = ""
        currentPartialRange = nil
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

    private func subtitleAttrs(fontSize: Double, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>, default defaultVal: Double) -> Double {
        guard self >= range.lowerBound && self <= range.upperBound else { return defaultVal }
        return self
    }
}
