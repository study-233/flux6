import Foundation

/// Only this compiled catalog supplies hashes, destinations and architectures.
/// The XPC caller supplies an ID and an open descriptor, never these fields.
struct ApprovedResource {
    let id: String
    let filename: String
    let sha256: String
    let size: Int?
    let archiveSHA256: String?
    let architecture: String?
    var archiveName: String? = nil
    var limit: Int { size ?? ApprovedResourceCatalog.maximumBytes }
    var mode: mode_t { architecture == nil ? 0o400 : 0o500 }
}

enum ApprovedResourceCatalog {
    static let maximumBytes = 150 * 1024 * 1024
    static var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "amd64"
        #else
        return "unsupported"
        #endif
    }
    static var native: [ApprovedResource] {
        pinned.filter { $0.architecture == nil || $0.architecture == nativeArchitecture }
    }
    static func asset(_ id: String) throws -> ApprovedResource {
        guard let asset = native.first(where: { $0.id == id }) else { throw ResourceStoreError.unapproved }
        return asset
    }
    static func requirePair(runtimeID: String, geodataID: String) throws {
        let geodata = native.filter { $0.architecture == nil }
        guard native.first(where: { $0.architecture != nil })?.id == runtimeID,
              geodata.count == 3, geodata.allSatisfy({ $0.id.hasPrefix(geodataID + "/") }) else {
            throw ResourceStoreError.unapproved
        }
    }
}

public enum ResourceStoreError: Error, LocalizedError {
    case unapproved, invalidSource, integrity, invalidArchive, tooLarge, busy, io, timedOut
    public var errorDescription: String? {
        switch self {
        case .unapproved: return "资源版本或架构不在服务的可信清单中"
        case .invalidSource: return "资源必须是当前客户端拥有的普通文件"
        case .integrity: return "资源内容与服务的固定摘要或架构不一致"
        case .invalidArchive: return "核心压缩包格式无效"
        case .tooLarge: return "资源超过允许的大小"
        case .busy: return "网络服务正在验证另一项资源"
        case .io: return "资源存储操作失败"
        case .timedOut: return "资源验证超时"
        }
    }
}
