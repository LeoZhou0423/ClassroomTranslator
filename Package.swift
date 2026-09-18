// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClassroomTranslator",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClassroomTranslator", targets: ["ClassroomTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "ClassroomTranslator",
            path: "ClassroomTranslator"
        )
    ]
)
