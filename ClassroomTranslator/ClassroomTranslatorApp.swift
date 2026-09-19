import SwiftUI
import ObjectiveC

@main
@MainActor
struct ClassroomTranslatorApp: App {
    @State private var historyStore = HistoryStore()

    init() {
        Self.applyAppLanguage()
        Self.installConstraintExceptionGuard()
    }

    static func applyAppLanguage() {
        let pref = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
        if pref == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([pref], forKey: "AppleLanguages")
        }
    }

    /// macOS 26/27 workaround: NSHostingView.layout() 在 display cycle 期间
    /// flush transactions 时可能触发 _postWindowNeedsUpdateConstraints 重入，
    /// AppKit 抛出 NSException 导致 abort（已知框架 bug，多个项目受影响）。
    /// Swizzle NSHostingView.layout()，用 re-entrancy guard 阻止重入调用。
    private static func installConstraintExceptionGuard() {
        guard let hostingClass = NSClassFromString("SwiftUI.NSHostingView") as? AnyClass,
              let original = class_getInstanceMethod(hostingClass, #selector(NSView.layout)) else {
            return
        }

        let originalIMP = method_getImplementation(original)
        let sel = #selector(NSView.layout)

        // 用 re-entrancy guard 替换 layout：重入时直接跳过
        let newIMP: @convention(block) (AnyObject) -> Void = { host in
            guard !Self.isInLayout else { return }
            Self.isInLayout = true
            defer { Self.isInLayout = false }

            typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
            let fn = unsafeBitCast(originalIMP, to: LayoutFn.self)
            fn(host, sel)
        }
        method_setImplementation(original, imp_implementationWithBlock(newIMP))
    }

    /// 主线程 re-entrancy flag：防止 NSHostingView.layout() 重入
    nonisolated(unsafe) static var isInLayout = false

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(historyStore)
        }
        .defaultSize(width: 700, height: 500)

        Settings {
            SettingsView()
        }
    }
}
