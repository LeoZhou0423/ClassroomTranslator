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
    targets: [
        .executableTarget(
            name: "ClassroomTranslator",
            path: "ClassroomTranslator",
            resources: [
                .copy("Resources/AccentECAPA.mlpackage"),
                .copy("Resources/labels.json"),
                .copy("Resources/zh-Hans.lproj"),
                .copy("Resources/AppIcon.png")
            ]
        ),
        .testTarget(
            name: "ClassroomTranslatorTests",
            dependencies: ["ClassroomTranslator"],
            path: "Tests/ClassroomTranslatorTests"
        )
    ]
)
