import Foundation
import SwiftUI
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Whisper（WhisperKit）模型预下载与进度 —— 大模型必须先下完再开录，
/// 否则 start() 会和录音启动超时互相打断（用户实测：下载中被打断）。
/// 档位由 WhisperModelTier（按内存/VM 推荐）选择，可覆盖。
@MainActor
@Observable
final class WhisperModelStore {
    static let shared = WhisperModelStore()

    var isDownloading = false
    /// 0...1，未知时为 nil
    var fraction: Double?
    var message: String = ""
    var lastError: String?
    var isReady: Bool = false
    /// 当前档位（默认按硬件推荐，可被设置覆盖）
    var tier: WhisperModelTier

    private init() {
        tier = WhisperModelTier()
        refreshReadyFlag()
    }

    var variant: String { tier.variantName }

    func selectTier(_ tier: WhisperModelTier) {
        guard tier != self.tier else { return }
        self.tier = tier
        UserDefaults.standard.set(tier.rawValue, forKey: WhisperModelTier.defaultsKey)
        isReady = false
        fraction = nil
        lastError = nil
        message = String(localized: "Whisper model not downloaded")
        refreshReadyFlag()
    }

    func refreshReadyFlag() {
        if Self.localModelFolderExists(variant: tier.variantName) {
            isReady = true
            if message.isEmpty {
                message = String(localized: "Whisper model ready.")
            }
        }
    }

    static func localModelFolderExists(variant: String) -> Bool {
        let fm = FileManager.default
        let candidates = [
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("whisperkit", isDirectory: true),
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("whisperkit", isDirectory: true),
        ]
        let needle = variant.lowercased()
        return candidates.contains { url in
            guard let url else { return false }
            guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
            return items.contains { $0.lowercased().contains(needle) }
        }
    }

    /// 预下载当前档位权重。可重复调用。
    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        lastError = nil
        fraction = 0
        message = String(localized: "Downloading Whisper model…")
        defer { isDownloading = false }

        do {
            #if canImport(WhisperKit)
            let variant = tier.variantName
            _ = try await WhisperKit.download(variant: variant) { [weak self] progress in
                Task { @MainActor in
                    self?.fraction = progress.fractionCompleted
                    self?.message = String(
                        format: String(localized: "Downloading Whisper model… %lld%%"),
                        Int(progress.fractionCompleted * 100)
                    )
                }
            }
            isReady = true
            fraction = 1
            message = String(localized: "Whisper model ready.")
            StartupLog.mark("whisper.model-downloaded variant=\(variant)")
            #else
            lastError = "WhisperKit not linked"
            message = String(localized: "Whisper is not available in this build.")
            #endif
        } catch {
            lastError = error.localizedDescription
            message = String(localized: "Whisper model download failed. Check the network and try again.")
            StartupLog.mark("whisper.model-download-failed \(error.localizedDescription)")
        }
    }
}
