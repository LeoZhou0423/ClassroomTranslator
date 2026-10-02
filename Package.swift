// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClassroomTranslator",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "ClassroomTranslator", targets: ["ClassroomTranslator"])
    ],
    dependencies: [
        // task-6 Step 2：sherpa-onnx 双引擎（SherpaSpeechEngine）。本仓库
        // .gitignore 忽略 Package.resolved，版本钉死必须写在这个 exact
        // requirement 里（Lead 确认）；传递依赖 onnxruntime-libs 由上游
        // Package.swift 以 exact 1.28.2 钉死。
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
        // Whisper ASR（WhisperKit / CoreML）：课堂嘈杂与 TTS 下比 Dictation 更稳。
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0")
    ],
    targets: [
        .executableTarget(
            name: "ClassroomTranslator",
            dependencies: [
                // 暴露 target SherpaOnnx（其 sources 即官方 swift-api-examples/
                // SherpaOnnx.swift 薄封装，import SherpaOnnx 即用）。
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "ClassroomTranslator",
            resources: [
                .copy("Resources/AccentECAPA.mlpackage"),
                .copy("Resources/labels.json"),
                .copy("Resources/zh-Hans.lproj"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/SpeakerCAMWaveZHEng.mlpackage"),
                .copy("Resources/SherpaStreamEN"),
                .copy("Resources/role_vocab.txt"),
                // TalkMoves MiniLM 老师/学生二分类（生产角色识别）
                .copy("Resources/RoleMiniLM.mlpackage")
            ]
        ),
        .testTarget(
            name: "ClassroomTranslatorTests",
            dependencies: ["ClassroomTranslator"],
            path: "Tests/ClassroomTranslatorTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
