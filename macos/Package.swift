// swift-tools-version: 5.9
import PackageDescription
import Foundation

let bootstrapManifest = ProcessInfo.processInfo.environment["FREEV6_BOOTSTRAP_MANIFEST"]
let bootstrapLinkerSettings: [LinkerSetting] = bootstrapManifest.map {
    [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", $0])]
} ?? []

let package = Package(
    name: "FreeV6Mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FreeV6", targets: ["FreeV6App"]),
        .executable(name: "freev6-probe", targets: ["FreeV6Probe"]),
        .executable(name: "freev6-network-service", targets: ["FreeV6NetworkService"]),
        .executable(name: "freev6-service-installer", targets: ["FreeV6Bootstrap"]),
        .library(name: "FreeV6System", targets: ["FreeV6System"]),
    ],
    targets: [
        .target(name: "FreeV6System"),
        .target(name: "FreeV6Business"),
        .executableTarget(name: "FreeV6App", dependencies: ["FreeV6System", "FreeV6Business"]),
        .executableTarget(name: "FreeV6Probe", dependencies: ["FreeV6System"]),
        .executableTarget(name: "FreeV6NetworkService", dependencies: ["FreeV6System"]),
        .executableTarget(name: "FreeV6Bootstrap", dependencies: ["FreeV6System"], linkerSettings: bootstrapLinkerSettings),
        .testTarget(name: "FreeV6SystemTests", dependencies: ["FreeV6System"]),
        .testTarget(name: "FreeV6BusinessTests", dependencies: ["FreeV6Business"]),
    ]
)
