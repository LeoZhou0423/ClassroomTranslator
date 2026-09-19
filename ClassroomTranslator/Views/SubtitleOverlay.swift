import SwiftUI
import AppKit

/// 共享数据源：controller 和 SwiftUI view 都引用同一个实例，修改实时反映到 UI
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
    
    func updateSegments(_ segments: [(original: String, translated: String)], currentText: String = "") {
        state.segments = segments
        state.currentText = currentText
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
    @State private var fontSize: CGFloat = 20
    @State private var opacity: Double = 0.85
    
    var body: some View {
        VStack(spacing: 8) {
            // 最新一句话的翻译（实时字幕）
            if let last = state.segments.last, !last.translated.isEmpty {
                Text(last.translated)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .id("translated")
            }
            
            // 当前正在识别的 partial
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
        .background(Color.black.opacity(opacity))
    }
}
