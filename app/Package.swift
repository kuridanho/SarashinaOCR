// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SarashinaOCR",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SarashinaOCR", targets: ["SarashinaOCR"])
    ],
    targets: [
        .executableTarget(
            name: "SarashinaOCR",
            path: "Sources/SarashinaOCR",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "SarashinaOCRTests",
            dependencies: ["SarashinaOCR"],
            path: "Tests/SarashinaOCRTests"
        )
    ]
)
