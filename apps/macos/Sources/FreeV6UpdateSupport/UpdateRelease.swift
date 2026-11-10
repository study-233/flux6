import Foundation

public enum UpdateFailure: String, Error, LocalizedError, Codable, Sendable {
    case unconfigured, invalidHost, incompatible, invalidFeed, transport, installation, cancelled

    public var errorDescription: String? {
        switch self {
        case .unconfigured: return "此开发构建尚未配置正式更新通道，请使用最新 DMG。"
        case .invalidHost: return "请从完整安装的 Flux6 应用启动更新。"
        case .incompatible: return "此更新与当前架构、协议或配置格式不兼容。"
        case .invalidFeed: return "更新清单或安装包未通过验证。"
        case .transport: return "无法与更新助手通信，请重新检查更新。"
        case .installation: return "应用升级未完成，请重新打开应用并检查网络服务。"
        case .cancelled: return "已取消本次更新。"
        }
    }
}

public struct UpdateRelease: Codable, Equatable, Sendable {
    public let format: Int
    public let build: UInt64
    public let minimumSourceBuild: UInt64
    public let maximumSourceBuild: UInt64
    public let architecture: String
    public let workerProtocol: Int
    public let serviceProtocol: Int
    public let settingsSchema: Int
    public let runtimeCatalogSHA256: String
    public let serviceSHA256: String

    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    public static func decode(_ data: Data, currentBuild: UInt64) throws -> Self {
        guard data.count <= 4096 else { throw UpdateFailure.incompatible }
        let item = try JSONDecoder().decode(Self.self, from: data)
        try item.validate(currentBuild: currentBuild)
        return item
    }

    public func validate(currentBuild: UInt64) throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard format == 1, build > currentBuild, build <= 9_999_999_999, minimumSourceBuild > 0,
              minimumSourceBuild <= currentBuild, currentBuild <= maximumSourceBuild,
              maximumSourceBuild < build, architecture == Self.architecture,
              workerProtocol == 1, serviceProtocol == 6, settingsSchema == 1,
              digest(runtimeCatalogSHA256), digest(serviceSHA256) else { throw UpdateFailure.incompatible }
    }
}

public struct UpdateChannel {
    public let feed: URL
    public let publicKey: Data
    public let build: UInt64

    public init(info: [String: Any], allowLoopback: Bool = false) throws {
        guard let raw = info["SUFeedURL"] as? String, let feed = URL(string: raw),
              let key = info["SUPublicEDKey"] as? String, let data = Data(base64Encoded: key), data.count == 32,
              let buildText = info["CFBundleVersion"] as? String, let build = UInt64(buildText), build > 0 else {
            throw UpdateFailure.unconfigured
        }
        let local = allowLoopback && feed.scheme == "http" && feed.host == "127.0.0.1"
        guard (feed.scheme == "https" || local), feed.host?.isEmpty == false, feed.user == nil, feed.password == nil,
              feed.fragment == nil, feed.query == nil, feed.path.hasSuffix("/appcast-" + UpdateRelease.architecture + ".xml"),
              info["SURequireSignedFeed"] as? Bool == true, info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.intValue == 0,
              info["SURelaunchHostBundle"] as? Bool == true,
              info["SUAllowsAutomaticUpdates"] as? Bool == false else { throw UpdateFailure.invalidFeed }
        self.feed = feed
        self.publicKey = data
        self.build = build
    }
}
