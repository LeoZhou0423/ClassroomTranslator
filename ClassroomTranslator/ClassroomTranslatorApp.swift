import SwiftUI
import ObjectiveC

@main
@MainActor
struct ClassroomTranslatorApp: App {
    @State private var historyStore = HistoryStore()

    init() {
        Self.applyAppLanguage()
        Self.installLayoutExceptionGuard()
    }

    static func applyAppLanguage() {
        let pref = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
        if pref == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([pref], forKey: "AppleLanguages")
        }
    }

    /// macOS 26/27 workaround: NSHostingView.layout() → flushTransactions →
    /// setNeedsUpdateConstraints → _postWindowNeedsUpdateConstraints 抛异常。
    /// AppKit 的 display cycle observer 捕获后 re-throw → abort。
    ///
    /// 用 ObjC @try/@catch 包装 NSHostingView.layout()，
    /// 在 re-throw 路径上拦截异常，阻止 abort。
    private static func installLayoutExceptionGuard() {
        guard let hostingClass = NSClassFromString("SwiftUI.NSHostingView") as? AnyClass,
              let original = class_getInstanceMethod(hostingClass, #selector(NSView.layout)) else {
            return
        }

        let originalIMP = method_getImplementation(original)
        let sel = #selector(NSView.layout)

        let newIMP: @convention(block) (AnyObject) -> Void = { host in
            let ex = __tryCatch {
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                let fn = unsafeBitCast(originalIMP, to: Fn.self)
                fn(host, sel)
            }
            if let ex {
                print("[LingoClass] Suppressed layout exception: \(ex.name.rawValue)")
            }
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
