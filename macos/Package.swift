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
        .executable(name: "freev6-login-launcher", targets: ["FreeV6LoginLauncher"]),
        .executable(name: "freev6-probe", targets: ["FreeV6Probe"]),
        .executable(name: "freev6-network-service", targets: ["FreeV6NetworkService"]),
        .executable(name: "freev6-service-installer", targets: ["FreeV6Bootstrap"]),
        .library(name: "FreeV6System", targets: ["FreeV6System"]),
    ],
    targets: [
        .target(name: "FreeV6System", dependencies: ["FreeV6Configuration", "FreeV6UpdateSupport"]),
        .target(name: "FreeV6Configuration"),
        .target(name: "FreeV6UpdateSupport"),
        .target(name: "FreeV6Business", dependencies: ["FreeV6Configuration"]),
        .target(name: "FreeV6Desktop", dependencies: ["FreeV6System", "FreeV6UpdateSupport"]),
        .executableTarget(name: "FreeV6App", dependencies: ["FreeV6System", "FreeV6Business", "FreeV6Desktop", "FreeV6UpdateSupport"]),
        .executableTarget(name: "FreeV6LoginLauncher"),
        .executableTarget(name: "FreeV6Probe", dependencies: ["FreeV6System", "FreeV6Desktop"]),
        .executableTarget(name: "FreeV6NetworkService", dependencies: ["FreeV6System"]),
        .executableTarget(name: "FreeV6Bootstrap", dependencies: ["FreeV6System"], linkerSettings: bootstrapLinkerSettings),
        .testTarget(name: "FreeV6SystemTests", dependencies: ["FreeV6System"]),
        .testTarget(name: "FreeV6BusinessTests", dependencies: ["FreeV6Business"]),
        .testTarget(name: "FreeV6ConfigurationTests", dependencies: ["FreeV6Configuration"]),
        .testTarget(name: "FreeV6DesktopTests", dependencies: ["FreeV6Desktop", "FreeV6System"]),
        .testTarget(name: "FreeV6UpdateTests", dependencies: ["FreeV6UpdateSupport"]),
    ]
)

if let framework = ProcessInfo.processInfo.environment["FREEV6_SPARKLE_FRAMEWORK_DIR"] {
    var flags = ["-F", framework]
    if ProcessInfo.processInfo.environment["FREEV6_UPDATE_PROBE_BUILD"] == "1" { flags += ["-D", "FREEV6_UPDATE_PROBE"] }
    package.targets.append(.executableTarget(name: "FreeV6UpdateAgent", dependencies: ["FreeV6UpdateSupport"],
        swiftSettings: [.unsafeFlags(flags)],
        linkerSettings: [.unsafeFlags(["-F", framework, "-framework", "Sparkle",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]))
    package.products.append(.executable(name: "freev6-update-agent", targets: ["FreeV6UpdateAgent"]))
}
