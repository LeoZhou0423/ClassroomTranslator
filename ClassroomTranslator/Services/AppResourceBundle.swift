import Foundation

/// 打包后的资源解析。
///
/// SwiftPM 生成的 `Bundle.module` 只查两处：`Bundle.main.bundleURL + 资源包名`
/// （对 .app 即 app 根目录，codesign 报 "unsealed contents present in the bundle
/// root" 禁止放置）与构建机的硬编码绝对路径（只在构建机存在）。资源包实际被
/// 打包进 `Contents/Resources/`，于是任何在用户机器上首次访问 `Bundle.module`
/// 的代码都会 `Fatal error: could not load resource bundle` → 进程 SIGILL
/// （虚拟机崩溃日志实证：点「新建录音」首次 SpeechManager 初始化时触发）。
///
/// 探测顺序：安装包布局 → 可执行文件同目录（swift run）→ 源码树 .build
/// （swift test：单测宿主 Bundle.main 不含资源，靠 #filePath 回到构建树）→
/// SwiftPM 原路径兼容 → 全部落空时回退 Bundle.main 并记日志，绝不 fatal；
/// 由各调用点已有的降级路径（模型缺失 → 英语引擎/无说话人标签）承接。
extension Bundle {
    static let lingoResources: Bundle = {
        let name = "ClassroomTranslator_ClassroomTranslator.bundle"
        var candidates: [String] = []

        func appendIfPresent(_ path: String) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                candidates.append(path)
            }
        }

        // 1) 安装包布局：LingoClass.app/Contents/Resources/<bundle>（CI 打包拷贝位置）
        if let resources = Bundle.main.resourceURL {
            appendIfPresent(resources.appendingPathComponent(name).path)
        }
        // 2) 开发期裸可执行/swift run：资源包与可执行文件同目录
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            appendIfPresent(exe.appendingPathComponent(name).path)
        }
        // 3) swift test：测试宿主（xctest）不含资源，从源码树定位 .build 构建产物。
        //    安装包里 #filePath 指向构建机路径、不存在，此段自然跳过。
        var sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            sourceDir.deleteLastPathComponent()
            let buildDir = sourceDir.appendingPathComponent(".build")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: buildDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let configs = ["debug", "release"]
            var layouts: [URL] = []
            for config in configs {
                layouts.append(buildDir.appendingPathComponent(config))
            }
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: buildDir.path) {
                for entry in entries {
                    guard entry != "debug", entry != "release" else { continue }
                    for config in configs {
                        layouts.append(buildDir.appendingPathComponent(entry).appendingPathComponent(config))
                    }
                }
            }
            for layout in layouts {
                appendIfPresent(layout.appendingPathComponent(name).path)
            }
            break
        }
        // 4) SwiftPM 生成访问器的原路径（app 根 / swift run 布局；留作兼容）
        appendIfPresent(Bundle.main.bundleURL.appendingPathComponent(name).path)

        if let path = candidates.first, let bundle = Bundle(path: path) {
            return bundle
        }
        NSLog("[AppResourceBundle] resource bundle not found, candidates=%@", candidates.joined(separator: "; "))
        return Bundle.main
    }()
}
