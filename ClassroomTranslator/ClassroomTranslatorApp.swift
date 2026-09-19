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
    /// 用 ObjC @try/@catch 包装 layout()，吞掉重入异常。
    private static func installConstraintExceptionGuard() {
        guard let hostingClass = NSClassFromString("SwiftUI.NSHostingView") as? AnyClass,
              let original = class_getInstanceMethod(hostingClass, #selector(NSView.layout)) else {
            return
        }

        let originalIMP = method_getImplementation(original)

        // 替换为带异常捕获的实现，闭包直接捕获 originalIMP
        let newIMP: @convention(block) (AnyObject) -> Void = { host in
            let ex = __tryCatch {
                typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
                let fn = unsafeBitCast(originalIMP, to: LayoutFn.self)
                fn(host, #selector(NSView.layout))
            }
            if let ex {
                print("[LingoClass] Suppressed NSHostingView layout exception: \(ex.name.rawValue)")
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
