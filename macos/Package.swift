// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeV6Mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FreeV6", targets: ["FreeV6App"]),
        .executable(name: "freev6-probe", targets: ["FreeV6Probe"]),
        .library(name: "FreeV6System", targets: ["FreeV6System"]),
    ],
    targets: [
        .target(name: "FreeV6System"),
        .executableTarget(name: "FreeV6App", dependencies: ["FreeV6System"]),
        .executableTarget(name: "FreeV6Probe", dependencies: ["FreeV6System"]),
        .testTarget(name: "FreeV6SystemTests", dependencies: ["FreeV6System"]),
    ]
)
