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
    @AppStorage("detectedRecognitionLanguage") private var detectedLanguage = ""
    @AppStorage("translationTarget") private var target = "zh-Hans"
    @State private var config = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "zh-Hans")
    )
    /// 实际下发给系统的语言对（用于判断是否真的需要重建 Configuration）。
    @State private var appliedSource = ""
    @State private var appliedTarget = ""

    init(manager: TranslationManager, sourceLanguage: String?, targetLanguage: String?, content: Content) {
        self.manager = manager
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.content = content
        let savedSource = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "auto"
        let selectedSource = sourceLanguage ?? savedSource
        let source = TranslationManager.resolveAutoSource(selectedSource)
        let target = targetLanguage ?? UserDefaults.standard.string(forKey: "translationTarget") ?? "zh-Hans"
        let sessionTarget = Self.sessionTarget(source: source, desiredTarget: target)
        _config = State(initialValue: TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: sessionTarget)
        ))
        _appliedSource = State(initialValue: source)
        _appliedTarget = State(initialValue: sessionTarget)
    }

    var body: some View {
        content
            .onAppear {
                Task { @MainActor in
                    let source = TranslationManager.resolveAutoSource(sourceLanguage ?? language)
                    manager.configureLanguagePair(source: source, target: targetLanguage ?? target)
                    syncConfig()
                }
            }
            // 视图消失后系统会作废本次会话，先丢弃缓存，别让收尾的翻译再用它。
            .onDisappear { manager.detachSession() }
            .onChange(of: language) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: detectedLanguage) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: target) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: sourceLanguage) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: targetLanguage) { _, _ in Task { @MainActor in syncConfig() } }
            .onChange(of: manager.sessionRefreshToken) { _, _ in
                Task { @MainActor in
                    manager.detachSession()
                    config.invalidate()
                }
            }
            .translationTask(config) { session in
                let source = TranslationManager.resolveAutoSource(sourceLanguage ?? language)
                manager.attach(session: session, sourceLanguage: source, targetLanguage: targetLanguage ?? target)
            }
    }

    private func syncConfig() {
        // Course language wins; auto follows the last detected recognition locale.
        let selectedSource = sourceLanguage ?? language
        let src = TranslationManager.resolveAutoSource(selectedSource)
        let tgt = targetLanguage ?? target
        manager.configureLanguagePair(source: src, target: tgt)
        let sessionTarget = Self.sessionTarget(source: src, desiredTarget: tgt)
        // 只有"跨语言"的变化才重建 Configuration。Auto English 在录音中把 en-GB 换成
        // en-US 属于同一语言内的方言切换：系统会因 source 变化作废旧会话并重新下发，
        // 录音期间这会让进行中的 translate 撞上已失效的会话（Apple 文档写明会 fatalError）。
        let sourceChanged = Self.baseLanguage(appliedSource) != Self.baseLanguage(src)
        let targetChanged = appliedTarget != sessionTarget
        guard sourceChanged || targetChanged else { return }
        manager.detachSession()
        appliedSource = src
        appliedTarget = sessionTarget
        config = TranslationSession.Configuration(
            source: Locale.Language(identifier: src),
            target: Locale.Language(identifier: sessionTarget)
        )
    }

    private static func baseLanguage(_ identifier: String) -> String {
        identifier.split(separator: "-").first.map(String.init) ?? identifier
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
