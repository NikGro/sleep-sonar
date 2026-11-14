// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SonarDSP",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SonarDSP", targets: ["SonarDSP"])
    ],
    targets: [
        .target(name: "SonarDSP"),
        .testTarget(name: "SonarDSPTests", dependencies: ["SonarDSP"])
    ]
)
