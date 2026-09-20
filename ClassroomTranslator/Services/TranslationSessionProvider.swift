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
    let sourceLanguage: String?
    let targetLanguage: String?
    let content: Content

    @AppStorage("recognitionLanguage") private var language = "auto"
    @AppStorage("translationTarget") private var target = "zh-Hans"
    @State private var config = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "zh-Hans")
    )

    init(manager: TranslationManager, sourceLanguage: String?, targetLanguage: String?, content: Content) {
        self.manager = manager
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.content = content
        let savedSource = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "auto"
        let selectedSource = sourceLanguage ?? savedSource
        let source = selectedSource == "auto" ? "en-US" : selectedSource
        let target = targetLanguage ?? UserDefaults.standard.string(forKey: "translationTarget") ?? "zh-Hans"
        let sessionTarget = Self.sessionTarget(source: source, desiredTarget: target)
        _config = State(initialValue: TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: sessionTarget)
        ))
    }

    var body: some View {
        content
            .onAppear {
                Task { @MainActor in
                    let source = (sourceLanguage ?? language) == "auto" ? "en-US" : (sourceLanguage ?? language)
                    manager.configureLanguagePair(source: source, target: targetLanguage ?? target)
                    syncConfig()
                }
            }
            .onChange(of: language) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: target) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: sourceLanguage) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: targetLanguage) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: manager.sessionRefreshToken) { _, _ in
                Task { @MainActor in config.invalidate() }
            }
            .translationTask(config) { session in
                let source = (sourceLanguage ?? language) == "auto" ? "en-US" : (sourceLanguage ?? language)
                manager.attach(session: session, sourceLanguage: source, targetLanguage: targetLanguage ?? target)
            }
    }

    private func syncConfig() {
        // auto → en-US；课程指定语言优先于全局设置，避免识别语言和翻译源语言不一致。
        let selectedSource = sourceLanguage ?? language
        let src = selectedSource == "auto" ? "en-US" : selectedSource
        let tgt = targetLanguage ?? target
        manager.configureLanguagePair(source: src, target: tgt)
        let sessionTarget = Self.sessionTarget(source: src, desiredTarget: tgt)
        let newSource = Locale.Language(identifier: src)
        let newTarget = Locale.Language(identifier: sessionTarget)
        // 只在真正变化时才更新，避免频繁 invalidate 触发系统断言
        if config.source != newSource || config.target != newTarget {
            config = TranslationSession.Configuration(
                source: newSource,
                target: newTarget
            )
        }
    }

    private static func sessionTarget(source: String, desiredTarget: String) -> String {
        let sourceBase = source.split(separator: "-").first.map(String.init) ?? source
        let targetBase = desiredTarget.split(separator: "-").first.map(String.init) ?? desiredTarget
        guard sourceBase == targetBase else { return desiredTarget }
        return sourceBase == "zh" ? "en-US" : "zh-Hans"
    }
}
#endif

/// 全版本兼容外壳：macOS 15 走 TranslationSessionHost，否则透传。
struct TranslationSessionCompat: ViewModifier {
    let manager: TranslationManager
    var sourceLanguage: String? = nil
    var targetLanguage: String? = nil

    func body(content: Content) -> some View {
        Group {
            #if canImport(Translation)
            if #available(macOS 15, *) {
                TranslationSessionHost(manager: manager, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, content: content)
            } else {
                content
            }
            #else
            content
            #endif
        }
    }
}
