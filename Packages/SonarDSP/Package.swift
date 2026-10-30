// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonarDSP",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SonarDSP", targets: ["SonarDSP"])
    ],
    targets: [
        .target(name: "SonarDSP"),
        .testTarget(name: "SonarDSPTests", dependencies: ["SonarDSP"])
    ]
)
