import SwiftUI
import AppKit

/// The navigation destination owns the available size. Recording status and live
/// transcripts must not feed a changing intrinsic size back into NSWindow.
@MainActor
struct RecordingHost: NSViewRepresentable {
    let course: Course
    let historyStore: HistoryStore
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ nsView: NSHostingView<AnyView>, context: Context) {
        nsView.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        // Do not ask the hosted controls or transcript for their fitting size.
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 500)
    }

    private var content: AnyView {
        AnyView(RecordingView(course: course, onClose: onClose).environment(historyStore))
    }
}
