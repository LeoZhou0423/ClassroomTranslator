import SwiftUI
#if canImport(Translation)
import Translation

/// macOS 15+：通过 SwiftUI `.translationTask` 向系统申请 TranslationSession，
/// 再注入给 TranslationManager。TranslationSession 没有公开初始化器，
/// 这是唯一合法的获取方式。
@available(macOS 15, *)
struct TranslationSessionInjector: ViewModifier {
    // 跟随用户在设置里的选择：只申请当前需要的一对语言，
    // 系统只下载这一对的模型；换目标语言时 configuration 变化，
    // translationTask 会重新下发 session（只下新需要的那一对）
    @AppStorage("recognitionLanguage") private var recognitionLanguage = "en-GB"
    @AppStorage("translationTarget") private var translationTarget = "zh-Hans"
    let manager: TranslationManager

    private var configuration: TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: Locale.Language(identifier: recognitionLanguage),
            target: Locale.Language(identifier: translationTarget)
        )
    }

    func body(content: Content) -> some View {
        content.translationTask(configuration) { session in
            manager.attach(session: session)
        }
    }
}
#endif

/// 全版本兼容外壳：macOS 15 走注入器，macOS 14 直接透传。
struct TranslationSessionCompat: ViewModifier {
    let manager: TranslationManager

    func body(content: Content) -> some View {
        Group {
            #if canImport(Translation)
            if #available(macOS 15, *) {
                content.modifier(TranslationSessionInjector(manager: manager))
            } else {
                content
            }
            #else
            content
            #endif
        }
    }
}
