import Foundation
import Observation

/// 极薄的「当前有没有录音在进行」广播位（AuditReport UX-01 / PSY-01）。
///
/// 只在 sidebar / List 这一层消费，用来拦截 NavigationSplitView 的 selection 切换。
/// 绝不能把基于它的 SwiftUI 条件视图塞进 StableRecordingView 这个
/// NSViewControllerRepresentable 内部 —— 那正是 macOS 26 NSHostingView
/// 布局死循环的触发路径（见 StableRecordingView.swift 顶部注释）。
@Observable
@MainActor
final class RecordingActivity {
    static let shared = RecordingActivity()

    /// starting / recording / paused / interrupted / 正在收尾保存 期间为 true。
    private(set) var isActive = false

    private init() {}

    func markActive() {
        guard !isActive else { return }
        isActive = true
    }

    func markIdle() {
        guard isActive else { return }
        isActive = false
    }
}
