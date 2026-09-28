import Foundation
import SwiftUI
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Whisper（WhisperKit）模型预下载与进度 —— 大模型必须先下完再开录，
/// 否则 start() 会和录音启动超时互相打断（用户实测：下载中被打断）。
@MainActor
@Observable
final class WhisperModelStore {
    static let shared = WhisperModelStore()
    static let variant = "tiny"

    var isDownloading = false
    /// 0...1，未知时为 nil
    var fraction: Double?
    var message: String = ""
    var lastError: String?
    var isReady: Bool = false

    private init() {
        // 已缓存目录存在则认为就绪（WhisperKit 本地模型夹）。
        if Self.localModelFolderExists() {
            isReady = true
            message = String(localized: "Whisper model ready.")
        }
    }

    static func localModelFolderExists() -> Bool {
        // WhisperKit 默认下载到 Application Support / whisperkit 或 downloadBase。
        let fm = FileManager.default
        let candidates = [
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("whisperkit", isDirectory: true),
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("whisperkit", isDirectory: true),
        ]
        return candidates.contains { url in
            guard let url else { return false }
            guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
            return items.contains { $0.lowercased().contains("small") }
        }
    }

    /// 预下载 Whisper CoreML 权重。可重复调用；已有缓存会很快返回。
    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        lastError = nil
        fraction = 0
        message = String(localized: "Downloading Whisper model…")
        defer {
            isDownloading = false
        }

        do {
            #if canImport(WhisperKit)
            _ = try await WhisperKit.download(variant: Self.variant) { [weak self] progress in
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
            StartupLog.mark("whisper.model-downloaded variant=\(Self.variant)")
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
