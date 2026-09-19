import SwiftUI

@main
@MainActor
struct ClassroomTranslatorApp: App {
    @State private var historyStore = HistoryStore()

    init() {
        Self.applyAppLanguage()
        Self.installConstraintExceptionGuard()
    }

    /// App 内语言：默认中文，跟系统语言脱钩（改完需重启生效）
    static func applyAppLanguage() {
        let pref = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
        if pref == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([pref], forKey: "AppleLanguages")
        }
    }

    /// macOS 27 workaround: NSHostingView.layout() 在 display cycle 期间 flush
    /// transactions 时可能触发 _postWindowNeedsUpdateConstraints 重入，
    /// AppKit 抛出 NSException 导致 abort。Swift 无法捕获 ObjC 异常，
    /// 只能在 AppKit 层面 swizzle layout() 用 try-catch 兜底。
    private static func installConstraintExceptionGuard() {
        guard let hostingViewClass = NSClassFromString("SwiftUI.NSHostingView") as? AnyClass,
              let originalMethod = class_getInstanceMethod(hostingViewClass, #selector(NSView.layout)),
              let swizzleMethod = class_getInstanceMethod(
                ClassroomTranslatorApp.self,
                #selector(ClassroomTranslatorApp.swizzledLayout)
              ) else { return }

        method_exchangeImplementations(originalMethod, swizzleMethod)
    }

    @objc func swizzledLayout() {
        // swizzle 后这里调的是原始 NSHostingView.layout()
        // 用 ObjC 异常捕获包装，抑制 _postWindowNeedsUpdateConstraints 崩溃
        let exception = Self.__try { [self] in
            self.swizzledLayout()
        }
        if let exception {
            // 吞掉约束更新重入异常，让 display cycle 继续
            print("Suppressed NSHostingView layout exception: \(exception.name.rawValue) - \(exception.reason ?? "unknown")")
        }
    }

    /// ObjC 异常捕获桥接（Swift 本身不支持 @try/@catch）
    private static func __try(_ block: () -> Void) -> NSException? {
        return __tryCatch(block)
    }

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
