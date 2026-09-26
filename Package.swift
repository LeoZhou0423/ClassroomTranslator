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
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8")
    ],
    targets: [
        .executableTarget(
            name: "ClassroomTranslator",
            dependencies: [
                // 暴露 target SherpaOnnx（其 sources 即官方 swift-api-examples/
                // SherpaOnnx.swift 薄封装，import SherpaOnnx 即用）。
                .product(name: "sherpa-onnx", package: "sherpa-onnx")
            ],
            path: "ClassroomTranslator",
            resources: [
                .copy("Resources/AccentECAPA.mlpackage"),
                .copy("Resources/labels.json"),
                .copy("Resources/zh-Hans.lproj"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/SpeakerCAMWaveZHEng.mlpackage"),
                .copy("Resources/SherpaStreamEN")
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
