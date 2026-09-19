import SwiftUI
import AppKit

@MainActor
final class SubtitleState: ObservableObject {
    @Published var segments: [(original: String, translated: String)] = []
    @Published var currentText: String = ""
}

class SubtitleWindowController: NSWindowController {
    private let state = SubtitleState()
    private var overlayWasVisible = false

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

        let subtitleView = SubtitleView(state: state)
        window.contentView = NSHostingView(rootView: subtitleView)

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

    /// 追加一段翻译（去重：最后一段相同则不重复追加）
    func appendSegment(original: String, translated: String) {
        guard !translated.isEmpty else { return }
        if let last = state.segments.last, last.translated == translated { return }
        state.segments.append((original: original, translated: translated))
        state.currentText = ""
    }

    /// 更新 partial 文本（实时显示）
    func updateCurrentText(_ text: String) {
        state.currentText = text
    }

    func clearAll() {
        state.segments.removeAll()
        state.currentText = ""
    }

    func showWindow() {
        window?.orderFront(nil)
    }

    func hideWindow() {
        window?.orderOut(nil)
    }
}

struct SubtitleView: View {
    @ObservedObject var state: SubtitleState
    @AppStorage("fontSize") private var fontSize: Double = 20
    @AppStorage("overlayOpacity") private var overlayOpacity: Double = 0.85

    var body: some View {
        VStack(spacing: 8) {
            // 只显示最后一句翻译（实时字幕）
            if let last = state.segments.last, !last.translated.isEmpty {
                Text(last.translated)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .id("translated")
            }

            // 当前正在识别的 partial（英文原文，小字）
            if !state.currentText.isEmpty {
                Text(state.currentText)
                    .font(.system(size: fontSize - 4, weight: .regular))
                    .foregroundColor(.yellow)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .id("current")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(overlayOpacity))
    }
}
