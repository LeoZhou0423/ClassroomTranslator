import Foundation

/// 启动流程面包屑：崩溃后没有 .ips 报告时，用这个日志定位死在哪一步。
/// 写入 ~/Library/Logs/LingoClass-startup.log
enum StartupLog {
    static func markEnvironment() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let path = Bundle.main.bundlePath
        mark("env os=\(os) path=\(path)")
    }

    static func mark(_ event: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(event)\n".data(using: .utf8) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        let url = dir.appendingPathComponent("LingoClass-startup.log")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 诊断日志失败不影响主流程
        }
    }
}
