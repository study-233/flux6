import Foundation

public enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case rule, global, direct
    public var title: String {
        switch self { case .rule: return "规则"; case .global: return "全局"; case .direct: return "直连" }
    }
}

public struct ProxyPreferences: Codable, Equatable, Sendable {
    public var mode: ProxyMode
    public var campusCidrs: [String]
    public var blacklist: [String]
    public var devMode: Bool
}

public struct ChainSummary: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case file, url }
    public let source: Source
    public let enabled: Bool
    public let names: [String]
}

public struct CloudSummary: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case file, url, portal }
    public let source: Source
    public let enabled: Bool
    public let names, ignored: [String]
    public let updatedAt: String
    public let id: UUID
}

public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: UInt64
    public let settings: ProxyPreferences
    public let chain: ChainSummary?
    public let cloud: CloudSummary?
    public let portalHost: String?
}

public struct WorkerHandshake: Decodable, Sendable {
    public let protocolVersion: Int
    public let workerVersion: String
    public let platform: String
    public let architecture: String
    public let capabilities: [String]
    public let maxFrameBytes: Int
    public let maxInFlight: Int
}

public struct RuntimePackageInfo: Decodable, Sendable, Equatable {
    public let resourceId: String
    public let version: String
    public let platform: String
    public let architecture: String
    public let archive: String
    public let sha256: String
    public let binarySha256: String
    public let available: Bool
}

public struct WorkerProgress: Decodable, Sendable {
    public let requestId: String
    public let sequence: UInt64
    public let phase: String
    public let received: Int64
    public let total: Int64
    public let attempt: Int
    public let attempts: Int
    public let asset: String?
}

public struct GeodataPackageInfo: Decodable, Sendable, Equatable {
    public struct File: Decodable, Sendable, Equatable {
        public let name: String
        public let size: Int64
        public let sha256: String
        public let available: Bool
    }
    public let resourceId: String
    public let revision: String
    public let available: Bool
    public let files: [File]

    func validated() throws -> Self {
        func isHex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard isHex(revision, count: 40), resourceId == "geodata-\(revision)", files.count == 3,
              Set(files.map(\.name)) == Set(["GeoSite.dat", "geoip.dat", "country.mmdb"]),
              files.allSatisfy({ $0.size > 0 && $0.size <= 32 * 1024 * 1024 && isHex($0.sha256, count: 64) }),
              available == files.allSatisfy(\.available) else { throw WorkerClientError.invalidResponse }
        return self
    }
}

public struct WorkerRemoteError: Error, Decodable, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public var errorDescription: String? {
        switch code {
        case -32004: return "设置已被更新。请重新载入后再保存。"
        case -32005: return "无法读写配置。原文件已保留，请检查磁盘或重新载入确认状态。"
        case -32006: return "资源准备失败：\(message)"
        case -32007: return "WARP 注册未完成，请检查网络后重试。"
        case -32008: return "连接配置生成失败，请检查已保存的设置和凭据后重试。"
        case -32003: return "业务操作仍在处理或清理中，请稍后重试。"
        case -32602: return "请求内容无效：\(message)"
        case -32800: return "操作已取消或超时。请重新载入确认结果。"
        default: return "业务服务返回错误（\(code)）：\(message)"
        }
    }
}

public enum WorkerClientError: Error, LocalizedError, Sendable, Equatable {
    case notAvailable, invalidFrame, invalidResponse, disconnected, timeout, busy, incompatible, staleConfiguration
    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "应用内的业务组件不可用，请重新构建或安装完整应用。"
        case .invalidFrame, .invalidResponse: return "业务组件返回了无效数据，连接已关闭。"
        case .disconnected: return "业务组件已断开。请重新载入；未确认的更改不会显示为已保存。"
        case .timeout: return "业务组件响应超时。请重新载入确认保存结果。"
        case .busy: return "业务组件正在处理其他操作，请稍后重试。"
        case .incompatible: return "应用与业务组件的协议版本不兼容，请重新安装完整应用。"
        case .staleConfiguration: return "代理规则已变化，请重新检查连接配置。"
        }
    }
}

struct WorkerFrameDecoder {
    static let maximum = 1_048_576
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= Self.maximum else { throw WorkerClientError.invalidFrame }
            guard buffer.count >= size + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(size)))
            buffer = Data(buffer.dropFirst(size + 4))
        }
        guard buffer.count <= Self.maximum + 4 else { throw WorkerClientError.invalidFrame }
        return frames
    }
    func finish() throws {
        guard buffer.isEmpty else { throw WorkerClientError.invalidFrame }
    }
    static func encode(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximum else { throw WorkerClientError.invalidFrame }
        let size = UInt32(data.count)
        return Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + data
    }
}

public struct WorkerLocation: Sendable {
    public let executable: URL
    public let data: URL
    public let resources: URL
    public let cache: URL
    public let logs: URL

    public init(executable: URL, data: URL, resources: URL, cache: URL, logs: URL) {
        self.executable = executable; self.data = data; self.resources = resources
        self.cache = cache; self.logs = logs
    }

    public static func application(bundle: Bundle = .main) throws -> WorkerLocation {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let library = try manager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return WorkerLocation(
            executable: bundle.bundleURL.appendingPathComponent("Contents/Helpers/freev6-worker"),
            data: support.appendingPathComponent("dev.freev6.desktop"),
            resources: bundle.resourceURL ?? bundle.bundleURL.appendingPathComponent("Contents/Resources"),
            cache: caches.appendingPathComponent("dev.freev6.desktop"),
            logs: library.appendingPathComponent("Logs/dev.freev6.desktop")
        )
    }
}

public struct TrafficBytes: Codable, Equatable, Sendable {
    public let upload: UInt64
    public let download: UInt64
}

public struct TrafficReport: Codable, Equatable, Sendable {
    public let month: String
    public let monthly: TrafficBytes
    public let total: TrafficBytes
}
