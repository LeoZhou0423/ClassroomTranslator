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

        let attrString = NSMutableAttributedString()
        attrString.append(NSAttributedString(string: original, attributes: subtitleAttrs(fontSize: fontSize - 4, color: .systemYellow)))
        if !translated.isEmpty {
            attrString.append(NSAttributedString(string: "\n" + translated, attributes: subtitleAttrs(fontSize: fontSize, color: .white)))
        }

        if let range = currentPartialRange, let storage = textView.textStorage,
           range.location + range.length <= storage.length {
            storage.replaceCharacters(in: range, with: attrString)
        } else {
            if !textView.string.isEmpty {
                attrString.insert(NSAttributedString(string: "\n\n", attributes: [.foregroundColor: NSColor.clear]), at: 0)
            }
            textView.textStorage?.append(attrString)
        }
        currentPartialRange = nil
        partialEnglishRange = nil
        partialChineseRange = nil
        lastPartialOriginal = ""
        lastPartialTranslated = ""
        scrollToBottom()
    }

    private var lastPartialOriginal = ""
    private var lastPartialTranslated = ""
    private var partialEnglishRange: NSRange?
    private var partialChineseRange: NSRange?

    func updateCurrentText(original: String, translated: String) {
        guard !original.isEmpty else {
            removeCurrentPartial()
            return
        }
        let fontSize = UserDefaults.standard.double(forKey: "fontSize").clamped(to: 12...36, default: 20)
        let englishChanged = original != lastPartialOriginal
        let chineseChanged = translated != lastPartialTranslated
        guard englishChanged || chineseChanged else { return }

        guard let storage = textView.textStorage else { return }

        if let eRange = partialEnglishRange, eRange.location + eRange.length <= storage.length {
            if englishChanged {
                let engAttr = NSAttributedString(string: original, attributes: subtitleAttrs(fontSize: fontSize - 4, color: .systemYellow))
                let delta = engAttr.length - eRange.length
                storage.replaceCharacters(in: eRange, with: engAttr)
                partialEnglishRange = NSRange(location: eRange.location, length: engAttr.length)
                if let cRange = partialChineseRange {
                    partialChineseRange = NSRange(location: cRange.location + delta, length: cRange.length)
                }
            }
            if chineseChanged, let cRange = partialChineseRange, cRange.location + cRange.length <= storage.length {
                if translated.isEmpty {
                    storage.replaceCharacters(in: cRange, with: NSAttributedString())
                    partialChineseRange = nil
                } else {
                    let chinAttr = NSAttributedString(string: "\n" + translated, attributes: subtitleAttrs(fontSize: fontSize, color: .white))
                    storage.replaceCharacters(in: cRange, with: chinAttr)
                    partialChineseRange = NSRange(location: cRange.location, length: chinAttr.length)
                }
            }
        } else {
            if storage.length > 0 {
                storage.append(NSAttributedString(string: "\n", attributes: [.foregroundColor: NSColor.clear]))
            }
            let start = storage.length
            let engAttr = NSAttributedString(string: original, attributes: subtitleAttrs(fontSize: fontSize - 4, color: .systemYellow))
            storage.append(engAttr)
            partialEnglishRange = NSRange(location: start, length: engAttr.length)
            if !translated.isEmpty {
                let chinAttr = NSAttributedString(string: "\n" + translated, attributes: subtitleAttrs(fontSize: fontSize, color: .white))
                storage.append(chinAttr)
                partialChineseRange = NSRange(location: start + engAttr.length, length: chinAttr.length)
            }
        }

        currentPartialRange = NSRange(location: partialEnglishRange?.location ?? 0,
                                      length: (partialEnglishRange?.length ?? 0) + (partialChineseRange?.length ?? 0))
        lastPartialOriginal = original
        lastPartialTranslated = translated
        scrollToBottom()
    }

    func updateCurrentText(_ text: String) {
        updateCurrentText(original: text, translated: lastPartialTranslated)
    }

    private func removeCurrentPartial() {
        guard let range = currentPartialRange, let storage = textView.textStorage,
              range.location + range.length <= storage.length else {
            currentPartialRange = nil
            partialEnglishRange = nil
            partialChineseRange = nil
            return
        }
        var removeRange = range
        if range.location > 0 {
            let before = NSRange(location: range.location - 1, length: 1)
            if storage.attributedSubstring(from: before).string == "\n" {
                removeRange = NSRange(location: range.location - 1, length: range.length + 1)
            }
        }
        storage.deleteCharacters(in: removeRange)
        currentPartialRange = nil
        partialEnglishRange = nil
        partialChineseRange = nil
    }

    func clearAll() {
        textView.string = ""
        currentPartialRange = nil
        partialEnglishRange = nil
        partialChineseRange = nil
        lastPartialOriginal = ""
        lastPartialTranslated = ""
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
