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

public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: UInt64
    public let settings: ProxyPreferences
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

public struct WorkerRemoteError: Error, Decodable, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public var errorDescription: String? {
        switch code {
        case -32004: return "设置已被更新。请重新载入后再保存。"
        case -32005: return "无法读写配置。原文件已保留，请检查磁盘或重新载入确认状态。"
        case -32602: return "设置内容无效：\(message)"
        case -32800: return "操作已取消或超时。请重新载入确认结果。"
        default: return "业务服务返回错误（\(code)）：\(message)"
        }
    }
}

public enum WorkerClientError: Error, LocalizedError, Sendable, Equatable {
    case notAvailable, invalidFrame, invalidResponse, disconnected, timeout, busy, incompatible
    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "应用内的业务组件不可用，请重新构建或安装完整应用。"
        case .invalidFrame, .invalidResponse: return "业务组件返回了无效数据，连接已关闭。"
        case .disconnected: return "业务组件已断开。请重新载入；未确认的更改不会显示为已保存。"
        case .timeout: return "业务组件响应超时。请重新载入确认保存结果。"
        case .busy: return "业务组件正在处理其他操作，请稍后重试。"
        case .incompatible: return "应用与业务组件的协议版本不兼容，请重新安装完整应用。"
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
