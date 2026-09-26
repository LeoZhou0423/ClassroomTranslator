import Foundation

/// task-6 Step 1：语音引擎抽象层。
///
/// 协议边界 = 原 AudioEngineDriver 的对外面（start/stop/running/onAccentSamples/
/// setAccentCapture + start 携带的 4 个回调），外加 SpeechManager 实际依赖的
/// updateContext / setSpeakerCapture / speakerRing（task-4）。约束：
///  · SpeechManager 除构造行（SpeechEngineFactory.make()）外一行不改 ——
///    编排逻辑（权限、generation、口音检测、delta 提交、状态机）零触碰；
///  · AppleSpeechEngine 即原 AudioEngineDriver（更名 + 实现协议，签名零改动）；
///  · SherpaSpeechEngine（Step 2）实现同一协议后由工厂分叉。
protocol SpeechEngine: AnyObject {
    var running: Bool { get }

    /// 口音检测音频流：引擎内部 AccentAudioTee 经此回调送出（get/set 透传）。
    var onAccentSamples: (@Sendable ([Float], Int) -> Void)? { get set }

    /// task-4 说话人取窗环形缓冲：每个引擎自带一份，mic tap 里并联 append。
    var speakerRing: SpeakerAudioRing { get }

    func setAccentCapture(enabled: Bool)
    func setSpeakerCapture(enabled: Bool)
    func updateContext(phrases: [String])

    func start(
        localeIdentifier: String,
        contextPhrases: [String],
        onInterruption: @escaping @Sendable () -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void,
        onModelStatus: @escaping @Sendable (String) -> Void,
        onRecognition: @escaping @Sendable (String, Bool) -> Void
    ) async throws

    func stop()
}

/// 引擎选择（设置 key `speechEngine`，默认 apple）。
/// Step 2：sherpa 可用性 = 模型资源齐全且未被创建失败熔断
/// （SherpaSpeechEngine.isUsable，降级纪律同 task-4 模型缺失回退）。
enum SpeechEngineKind: String, CaseIterable {
    case apple
    case sherpa

    /// @AppStorage 与 UserDefaults 共用的 key。
    /// 注意：SettingsView 里 @AppStorage 用字面量 "speechEngine" 绑定
    /// （属性包装器参数取常量表达式更稳），单测 testDefaultsKeyIsSpeechEngine
    /// 锁住两者一致。
    static let defaultsKey = "speechEngine"
    static let fallback = SpeechEngineKind.apple

    init(userDefaults: UserDefaults = .standard) {
        let stored = userDefaults.string(forKey: Self.defaultsKey) ?? ""
        self = SpeechEngineKind(rawValue: stored) ?? Self.fallback
    }

    /// 是否已有可用实现。sherpa 见模型资源 + 熔断状态（Bundle.module 即
    /// 应用资源包；单测经 temp bundle 注入覆盖缺失路径）。
    var isAvailable: Bool {
        switch self {
        case .apple: return true
        case .sherpa: return SherpaSpeechEngine.isUsable()
        }
    }

    /// 实际会实例化的引擎：不可用 → 回退 apple 并记日志。
    var resolved: SpeechEngineKind {
        if isAvailable { return self }
        StartupLog.mark("engine.unavailable=\(rawValue) fallback=\(Self.fallback.rawValue)")
        return Self.fallback
    }
}

/// 按用户选择实例化引擎。Step 2 在此分叉：sherpa 不可用（模型缺失或
/// 创建失败熔断）→ 记日志回退 apple；init 均为轻量（sherpa 模型创建在
/// start() 后台线程，见 SherpaSpeechEngine）。
enum SpeechEngineFactory {
    static func make(userDefaults: UserDefaults = .standard, bundle: Bundle = .module) -> any SpeechEngine {
        let kind = SpeechEngineKind(userDefaults: userDefaults)
        switch kind {
        case .apple:
            return AppleSpeechEngine()
        case .sherpa:
            guard SherpaSpeechEngine.isUsable(bundle: bundle) else {
                StartupLog.mark("engine.sherpa-unavailable fallback=apple")
                return AppleSpeechEngine()
            }
            StartupLog.mark("engine.selected=sherpa")
            return SherpaSpeechEngine()
        }
    }
}
