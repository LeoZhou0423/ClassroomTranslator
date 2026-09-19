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

    /// macOS 26/27 workaround: SwiftUI 在 display cycle 期间 flush transactions
    /// 时触发 _postWindowNeedsUpdateConstraints 重入，AppKit 抛 NSException。
    /// 直接 swizzle 这个方法，重入时跳过执行（不抛异常）。
    private static func installConstraintExceptionGuard() {
        guard let windowClass = NSClassFromString("NSWindow") as? AnyClass else { return }
        let sel = NSSelectorFromString("_postWindowNeedsUpdateConstraints")
        guard let original = class_getInstanceMethod(windowClass, sel) else { return }

        let originalIMP = method_getImplementation(original)
        var inConstraintPass = false

        let newIMP: @convention(block) (AnyObject) -> Void = { window in
            guard !inConstraintPass else { return }
            inConstraintPass = true
            defer { inConstraintPass = false }

            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let fn = unsafeBitCast(originalIMP, to: Fn.self)
            fn(window, sel)
        }
        method_setImplementation(original, imp_implementationWithBlock(newIMP))
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
