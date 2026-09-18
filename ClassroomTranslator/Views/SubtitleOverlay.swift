import SwiftUI
import AppKit

class SubtitleWindowController: NSWindowController {
    private var subtitleView: SubtitleView!
    
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
        
        window.center()
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(segment.original)
                                .font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(.white)
                                .textSelection(.enabled)
                            
                            Text(segment.translated)
                                .font(.system(size: fontSize - 2, weight: .regular))
                                .foregroundColor(.cyan)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .id(index)
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
                withAnimation {
                    proxy.scrollTo(segments.count - 1, anchor: .bottom)
                }
            }
            .onChange(of: currentText) {
                withAnimation {
                    proxy.scrollTo("current", anchor: .bottom)
                }
            }
        }
        .background(Color.black.opacity(opacity))
    }
    
    func updateSegments(_ newSegments: [(original: String, translated: String)], currentText: String = "") {
        self.segments = newSegments
        self.currentText = currentText
    }
}
