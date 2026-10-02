import Foundation
import SwiftUI

/// 标点恢复模型（sherpa-onnx CT-Transformer zh-en）的预下载与就绪状态。
/// 294 MB 的权重不适合打进 bundle，沿用 WhisperModelStore 的
/// "Application Support + 主动下载 + 就绪标记" 模式。模型缺席时
/// `PunctuationRestorer` 原样返回文本（等于现状行为），永不阻塞录音。
@MainActor
@Observable
final class PunctuationModelStore {
    static let shared = PunctuationModelStore()

    var isDownloading = false
    /// 0...1，未知时为 nil
    var fraction: Double?
    var message: String = ""
    var lastError: String?
    var isReady = false

    /// 单文件模型（词表内嵌在 onnx metadata 里）。主源 huggingface，
    /// 镜像 hf-mirror（与 Tools/sherpa/download_models.py 同一思路）。
    static let minimumModelBytes: Int64 = 250_000_000
    private static let primaryURL = URL(string:
        "https://huggingface.co/csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/resolve/main/model.onnx")!
    private static let mirrorURL = URL(string:
        "https://hf-mirror.com/csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/resolve/main/model.onnx")!

    private init() {
        refreshReadyFlag()
    }

    nonisolated static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LingoClass/PunctuationModel", isDirectory: true)
    }

    nonisolated static var modelFileURL: URL {
        modelDirectory.appendingPathComponent("model.onnx")
    }

    nonisolated static func modelFilesPresent() -> Bool {
        let path = modelFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return false }
        return size >= minimumModelBytes
    }

    func refreshReadyFlag() {
        isReady = Self.modelFilesPresent()
        if isReady && message.isEmpty {
            message = String(localized: "Punctuation model ready.")
        }
    }

    /// 预下载权重。可重复调用；先主源后镜像，任一成功即止。
    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        lastError = nil
        fraction = 0
        message = String(localized: "Downloading punctuation model…")
        defer { isDownloading = false }
        do {
            try await fetchModel(from: Self.primaryURL)
            finishReady()
        } catch {
            do {
                fraction = 0
                StartupLog.mark("punct.primary-download-failed -> mirror \(error.localizedDescription)")
                try await fetchModel(from: Self.mirrorURL)
                finishReady()
            } catch {
                lastError = error.localizedDescription
                message = String(localized: "Punctuation model download failed. Check the network and try again.")
                StartupLog.mark("punct.download-failed \(error.localizedDescription)")
            }
        }
    }

    private func finishReady() {
        isReady = true
        fraction = 1
        message = String(localized: "Punctuation model ready.")
        StartupLog.mark("punct.model-downloaded")
    }

    private func fetchModel(from url: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.modelDirectory, withIntermediateDirectories: true)
        let (stream, response) = try await URLSession.shared.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let expected = Double(http.expectedContentLength)
        let temporary = Self.modelFileURL.appendingPathExtension("part")
        var written: Int64 = 0
        var lastLoggedFraction = -1.0
        defer { try? fm.removeItem(at: temporary) }
        do {
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    guard expected > 0 else { continue }
                    let current = Double(written) / expected
                    if current - lastLoggedFraction >= 0.01 {
                        lastLoggedFraction = current
                        fraction = current
                        message = String(
                            format: String(localized: "Downloading punctuation model… %lld%%"),
                            Int(current * 100))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
        }
        guard written >= Self.minimumModelBytes else {
            throw URLError(.cannotDecodeContentData)
        }
        try? fm.removeItem(at: Self.modelFileURL)
        try fm.moveItem(at: temporary, to: Self.modelFileURL)
    }
}
