import SwiftUI
import AppKit

class SubtitleWindowController: NSWindowController {
    private var subtitleView: SubtitleView!
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
        
        subtitleView = SubtitleView()
        window.contentView = NSHostingView(rootView: subtitleView)
        
        // 主窗口进全屏前收起悬浮窗（floating panel 会干扰全屏切换），退出后恢复
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
    
    func updateSegments(_ segments: [(original: String, translated: String)], currentText: String = "") {
        subtitleView.updateSegments(segments, currentText: currentText)
    }
    
    func showWindow() {
        window?.orderFront(nil)
    }
    
    func hideWindow() {
        window?.orderOut(nil)
    }
}

struct SubtitleView: View {
    @State private var segments: [(original: String, translated: String)] = []
    @State private var currentText: String = ""
    @State private var fontSize: CGFloat = 16
    @State private var opacity: Double = 0.85
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 流式：累积的已确认文本
                    if let last = segments.last, !last.original.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(last.original)
                                .font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(.white)
                                .textSelection(.enabled)
                            if !last.translated.isEmpty {
                                Text(last.translated)
                                    .font(.system(size: fontSize - 2, weight: .regular))
                                    .foregroundColor(.cyan)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .id("accumulated")
                    }
                    
                    if !currentText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentText)
                                .font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(.yellow)
                            Text("...")
                                .font(.system(size: fontSize - 2))
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .id("current")
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: segments.count) {
                withAnimation { proxy.scrollTo("accumulated", anchor: .bottom) }
            }
            .onChange(of: currentText) {
                withAnimation { proxy.scrollTo("current", anchor: .bottom) }
            }
        }
        .background(Color.black.opacity(opacity))
    }
    
    func updateSegments(_ newSegments: [(original: String, translated: String)], currentText: String = "") {
        self.segments = newSegments
        self.currentText = currentText
    }
}
