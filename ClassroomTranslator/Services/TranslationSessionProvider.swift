import SwiftUI
#if canImport(Translation)
import Translation

/// macOS 15+：用 `.translationTask` 向系统申请 TranslationSession 并注入
/// TranslationManager。TranslationSession 没有公开初始化器，这是唯一合法来源。
/// 会话交付不稳定（尤其临时签名包），提供 invalidate() 强制重新下发：
/// 点“下载模型”时发现会话缺失就失效重来，而不是直接让用户去系统设置。
@available(macOS 15, *)
struct TranslationSessionHost<Content: View>: View {
    let manager: TranslationManager
    let content: Content

    @AppStorage("recognitionLanguage") private var language = "auto"
    @AppStorage("translationTarget") private var target = "zh-Hans"
    @State private var config = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "zh-Hans")
    )

    var body: some View {
        content
            .onAppear { syncConfig() }
            .onChange(of: language) { _, _ in syncConfig() }
            .onChange(of: target) { _, _ in syncConfig() }
            .onChange(of: manager.sessionRefreshToken) { _, _ in
                config.invalidate()
            }
            .translationTask(config) { session in
                manager.attach(session: session)
            }
    }

    private func syncConfig() {
        // auto → en（翻译源语言始终是英语）
        let src = language == "auto" ? "en" : language
        config = TranslationSession.Configuration(
            source: Locale.Language(identifier: src),
            target: Locale.Language(identifier: target)
        )
    }
}
#endif

/// 全版本兼容外壳：macOS 15 走 TranslationSessionHost，否则透传。
struct TranslationSessionCompat: ViewModifier {
    let manager: TranslationManager

    func body(content: Content) -> some View {
        Group {
            #if canImport(Translation)
            if #available(macOS 15, *) {
                TranslationSessionHost(manager: manager, content: content)
            } else {
                content
            }
            #else
            content
            #endif
        }
    }
}