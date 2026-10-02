import SwiftUI
import AppKit

@MainActor
final class SubtitleWindowController: NSWindowController {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 180))
    private var overlayWasVisible = false
    private var latestRows: [SubtitlePair] = []
    private var latestOriginal = ""
    private var latestTranslation = ""
    /// task-4：当前字幕的说话人（nil = 无标签）。
    private var latestSpeaker: String?
    /// task-10：当前会话的人员映射（会话上下文经 showStableCue 传入；
    /// 昵称命中时前缀显示「王教授: 」，默认空 = 原 label）。
    private var latestAliases: [String: SpeakerAlias] = [:]

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
        // 返回 true 表示找到并恢复了上次保存的窗口位置。
        let restoredSavedFrame = window.setFrameAutosaveName("SubtitleOverlayFrame")

        self.init(window: window)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scrollView.hasVerticalScroller = true
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
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)), name: NSWindow.didResizeNotification, object: window)

        applyDisplaySettings()
        // VIS-05 / STAB-07：autosave 恢复优先；没有存档才落到屏幕底部居中。
        // 原来 window.center() 写在 setFrameAutosaveName 之后，会把用户拖好的位置盖掉。
        if !restoredSavedFrame {
            Self.placeAtBottomCenter(window)
        }
    }

    /// VIS-05：默认把悬浮窗放到可用屏幕底部居中，上方整块视野留给幻灯片。
    private static func placeAtBottomCenter(_ window: NSWindow) {
        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + 40
        ))
    }

    @objc private func windowDidResize(_ note: Notification) {
        renderLatestCue()
    }

    /// 字号随悬浮窗尺寸缩放（以默认 600x200 为基准 1.0x，取宽高缩放较小者，0.6x--4x）。
    private func fontScale() -> Double {
        guard let window else { return 1 }
        let size = window.frame.size
        guard size.width > 0, size.height > 0 else { return 1 }
        let scale = min(Double(size.width) / 600, Double(size.height) / 200)
        return min(max(scale, 0.6), 4.0)
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
        // VIS-06：这里原本会 hideWindow()。git blame 到 48881e0（2026-09-19）的注释是
        // 「主窗口进全屏前收起悬浮窗（floating panel 会干扰全屏切换），退出后恢复」，
        // 而当时 contentView 还是 NSHostingView；3a4eaf2 已把面板换成纯 AppKit NSTextView，
        // 且 collectionBehavior 一直声明着 .fullScreenAuxiliary。
        // 没有崩溃级理由 —— 投影全屏恰恰是最需要字幕的时候，因此不再隐藏。
        // 只保留记录，退出时的 showWindow() 维持原样（无隐藏时它基本是 no-op）。
        overlayWasVisible = window?.isVisible == true
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
    func showStableCue(
        original: String,
        translated: String,
        speaker: String? = nil,
        aliases: [String: SpeakerAlias] = [:]
    ) {
        guard !original.isEmpty || !translated.isEmpty else { return }
        latestRows = [SubtitlePair(id: nil, original: original, translated: translated, speaker: speaker)]
        latestOriginal = original
        latestTranslation = translated
        latestSpeaker = speaker
        latestAliases = aliases
        renderLatestCue()
    }

    func showTranscriptRows(_ rows: [SubtitlePair], aliases: [String: SpeakerAlias] = [:]) {
        latestRows = rows
        latestAliases = aliases
        renderLatestCue()
    }

    private func renderLatestCue() {
        let configuration = SubtitleDisplayConfiguration()
        let fontSize = max(configuration.fontSize * fontScale(), 12)
        let value = NSMutableAttributedString()
        for row in latestRows {
            if value.length > 0 { value.append(NSAttributedString(string: "\n\n")) }
            let original = SubtitleCueBuilder.cue(from: row.original, maximumWords: configuration.maximumWords, maximumCharacters: 120)
            let translated = row.translated
            if configuration.showOriginal, !original.isEmpty {
                value.append(NSAttributedString(
                    string: SpeakerLabels.prefix(row.speaker, aliases: latestAliases) + original,
                    attributes: subtitleAttrs(fontSize: max(fontSize - 4, 12), color: Self.softOriginalYellow)
                ))
            }
            if !translated.isEmpty {
                let prefix = configuration.showOriginal && !original.isEmpty ? "\n" : ""
                value.append(NSAttributedString(string: prefix + translated, attributes: subtitleAttrs(fontSize: fontSize, color: .white)))
            }
        }
        textView.textStorage?.setAttributedString(value)
        if configuration.autoScroll { scrollToBottom() }
    }

    func clearAll() {
        latestRows = []
        textView.string = ""
        latestOriginal = ""
        latestTranslation = ""
        latestSpeaker = nil
        latestAliases = [:]
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
        let configuration = SubtitleDisplayConfiguration()
        window?.backgroundColor = NSColor.black.withAlphaComponent(configuration.opacity)
        // VIS-05：默认 false（保持可拖动）；用户在设置里打开后悬浮窗不再吞掉点击。
        window?.ignoresMouseEvents = configuration.clickThrough
    }

    private func subtitleAttrs(fontSize: Double, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            // VIS-04：亮色投影 / 花哨 PPT 上的文字要有一圈描边才立得住。
            // 负值 = 先描边再填充；正值会变成空心字。
            .strokeColor: NSColor.black.withAlphaComponent(0.9),
            // NSNumber 而不是裸 Double：NSDictionary 只认 NSNumber。
            .strokeWidth: NSNumber(value: -1.0),
        ]
    }

    /// VIS-04：纯 #FFCC00 在深底上有"振动感"，换成柔和的 #FFD866。
    private static let softOriginalYellow = NSColor(srgbRed: 1.0, green: 0.847, blue: 0.4, alpha: 1.0)
}
