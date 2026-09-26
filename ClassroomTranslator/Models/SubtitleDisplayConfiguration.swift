import Foundation

struct SubtitleDisplayConfiguration: Equatable {
    let fontSize: Double
    let opacity: Double
    let maximumWords: Int
    let showOriginal: Bool
    let autoScroll: Bool
    /// VIS-05：悬浮窗是否让鼠标事件穿透。默认关闭，保住"可以拖动"这个能力。
    let clickThrough: Bool

    init(defaults: UserDefaults = .standard) {
        let storedFont = defaults.double(forKey: "fontSize")
        fontSize = (12...36).contains(storedFont) ? storedFont : 16
        let storedOpacity = defaults.double(forKey: "overlayOpacity")
        opacity = (0.3...1).contains(storedOpacity) ? storedOpacity : 0.85
        let storedWords = defaults.integer(forKey: "subtitleMaxWords")
        maximumWords = (6...18).contains(storedWords) ? storedWords : 12
        showOriginal = defaults.object(forKey: "showSubtitleOriginal") as? Bool ?? true
        autoScroll = defaults.object(forKey: "autoScroll") as? Bool ?? true
        clickThrough = defaults.object(forKey: "overlayClickThrough") as? Bool ?? false
    }
}
