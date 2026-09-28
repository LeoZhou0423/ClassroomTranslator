import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whisper 模型档位：按机器配置推荐，用户可改。
/// 同一 App 在 VM / 低配本上默认 tiny，避免 CoreML OOM 把进程打没。
enum WhisperModelTier: String, CaseIterable, Identifiable, Sendable {
    case tiny
    case base
    case small

    var id: String { rawValue }

    /// WhisperKit / HF 变体名
    var variantName: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return String(localized: "Whisper tiny · fastest, lowest RAM")
        case .base: return String(localized: "Whisper base · balanced")
        case .small: return String(localized: "Whisper small · best accuracy")
        }
    }

    /// 设置页一行说明
    var detail: String {
        switch self {
        case .tiny: return String(localized: "About 75 MB. Safer on virtual machines and 8 GB Macs.")
        case .base: return String(localized: "About 140 MB. Good default for 8–16 GB Macs.")
        case .small: return String(localized: "About 500 MB. Prefer 16 GB+ or when accuracy matters most.")
        }
    }

    static let defaultsKey = "whisperModelTier"
    static let fallback: WhisperModelTier = .tiny

    init(userDefaults: UserDefaults = .standard) {
        if let raw = userDefaults.string(forKey: Self.defaultsKey),
           let tier = WhisperModelTier(rawValue: raw) {
            self = tier
        } else {
            self = Self.recommended()
        }
    }

    /// 按物理内存 + 是否虚拟机推荐。
    static func recommended(
        physicalMemoryGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0,
        isVirtualMachine: Bool = detectVirtualMachine()
    ) -> WhisperModelTier {
        // VM / 模拟器：一律 tiny（QEMU 上 CoreML 分配容易崩）
        if isVirtualMachine { return .tiny }
        if physicalMemoryGB < 10 { return .tiny }
        if physicalMemoryGB < 18 { return .base }
        return .small
    }

    /// 常见虚拟化痕迹：sysctl / 进程名 / 硬件名。失败则当真机。
    static func detectVirtualMachine() -> Bool {
        #if os(macOS)
        if let model = sysctlString("hw.model")?.lowercased() {
            if model.contains("vmware") || model.contains("kvm")
                || model.contains("qemu") || model.contains("virtual")
                || model.contains("parallels") || model.contains("hyperv") {
                return true
            }
        }
        if sysctlString("machdep.cpu.brand_string")?.lowercased().contains("qemu") == true {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
