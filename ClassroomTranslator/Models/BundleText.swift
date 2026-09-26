import Foundation

/// 注入 locale 的显式 .strings 查表（task-8/9 CI 修复，run 36229026246 实证）。
///
/// 问题：`String(localized:bundle:locale:)` 的 locale 参数**不驱动表选择** ——
/// 表选择跟随进程语言（CI 测试进程 = en），即使注入 bundle 里躺着 zh-Hans 表
/// 也回 key（英文原文）。生产 App 靠进程语言 zh 所以一直正常，测试进程才暴露。
///
/// 解法：经典做法 —— 按 locale 候选定位 lproj 目录 → Bundle(path:) 直接读表，
/// 进程无关、locale 可注入、可单测。查不到回 key（= 英文原文兜底）。
enum BundleText {
    /// key 在注入 bundle 对应语言表里的值；无表/缺键 → key 原文。
    static func string(_ key: String, bundle: Bundle, locale: Locale) -> String {
        for identifier in localeCandidates(locale) {
            guard let path = lprojPath(identifier, bundle: bundle),
                  let languageBundle = Bundle(path: path) else { continue }
            let value = languageBundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key { return value }
        }
        return key
    }

    /// locale 候选序：完整 identifier → 语言+脚本（zh-Hans_CN → zh-Hans）→ 主语言（zh）。
    /// 去重保序。
    private static func localeCandidates(_ locale: Locale) -> [String] {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        var candidates = [locale.identifier]
        let parts = identifier.split(separator: "-").map(String.init)
        if parts.count >= 2 {
            candidates.append("\(parts[0])-\(parts[1])")
        }
        if let language = parts.first {
            candidates.append(language)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// lproj 可能在 bundle 根（生产主 bundle / .copy 铺平）或 Resources 子目录
    /// （SwiftPM 资源 bundle 的一种布局），两种都探。
    private static func lprojPath(_ identifier: String, bundle: Bundle) -> String? {
        bundle.path(forResource: identifier, ofType: "lproj")
            ?? bundle.path(forResource: identifier, ofType: "lproj", inDirectory: "Resources")
    }
}
