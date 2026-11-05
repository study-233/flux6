import Darwin
import Foundation

/// Parsed by the ordinary app before committing an import. The service uses
/// the same field checks on each imported outbound when it decodes a session.
public struct ImportedChainNodes: Decodable, Sendable {
    static let limit = 64
    public let names: [String]

    public init(from decoder: Decoder) throws {
        let nodes = try [Value](from: decoder)
        guard (1...Self.limit).contains(nodes.count) else { throw ConfigurationValidationError.invalid }
        names = try nodes.enumerated().map { index, node in
            do { return try Self.name(of: node) }
            catch { throw ChainImportValidationError(position: index + 1) }
        }
        guard Set(names).count == names.count else { throw ConfigurationValidationError.invalid }
    }

    private static func plain(_ value: Value, limit: Int = 4096) throws -> String {
        let text = try value.text
        guard text.utf8.count <= limit, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ConfigurationValidationError.invalid
        }
        return text
    }

    static func name(of node: Value) throws -> String {
        guard case .object(let object) = node, let kind = try object["type"]?.text else { throw ConfigurationValidationError.invalid }
        let base: Set<String> = ["name", "type", "server", "port", "dialer-proxy"]
        let tls: Set<String> = ["skip-cert-verify", "fingerprint"]
        let transports: Set<String> = ["network", "ws-opts", "grpc-opts", "alpn", "client-fingerprint"]
        var required = base
        let optional: Set<String>
        switch kind {
        case "socks5": optional = tls.union(["udp","tls","username","password"])
        case "http": optional = tls.union(["tls","username","password","sni","headers"])
        case "ss": required.formUnion(["password","cipher"]); optional = ["udp","udp-over-tcp","udp-over-tcp-version"]
        case "trojan":
            required.insert("password")
            optional = transports.union(tls).union(["sni","udp"])
        case "vless":
            required.insert("uuid")
            optional = transports.union(tls).union(["servername","flow","tls","udp","reality-opts","packet-encoding","xudp"])
        case "vmess":
            required.formUnion(["uuid","cipher"])
            optional = transports.union(tls).union(["servername","alterId","tls","udp","packet-encoding"])
        default: throw ConfigurationValidationError.invalid
        }
        let fields = try node.object(required: required, optional: optional)
        let name = try plain(fields["name"]!, limit: 128)
        let host = try plain(fields["server"]!, limit: 253)
        let hostname = host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
        guard !name.isEmpty, !host.isEmpty, hostname || validIPAddress(host, family: AF_INET6),
              try fields["dialer-proxy"]!.text == "🚀 节点选择" else { throw ConfigurationValidationError.invalid }
        _ = try fields["port"]!.number(in: 1...65535)
        for (key, value) in fields where !base.contains(key) {
            switch key {
            case "udp","tls","skip-cert-verify","udp-over-tcp","xudp": try value.boolean()
            case "alterId": _ = try value.number(in: 0...65535)
            case "udp-over-tcp-version": _ = try value.number(in: 1...2)
            case "uuid": guard UUID(uuidString: try value.text) != nil else { throw ConfigurationValidationError.invalid }
            case "network": guard ["tcp","ws","grpc"].contains(try value.text) else { throw ConfigurationValidationError.invalid }
            case "ws-opts":
                guard try fields["network"]?.text == "ws" else { throw ConfigurationValidationError.invalid }
                let ws = try value.object(required: [], optional: ["path","headers","max-early-data","early-data-header-name"])
                if let path = ws["path"] { guard try plain(path).hasPrefix("/") else { throw ConfigurationValidationError.invalid } }
                if let headers = ws["headers"] { try validateHeaders(headers) }
                if let size = ws["max-early-data"] { _ = try size.number(in: 0...65535) }
                if let header = ws["early-data-header-name"] { _ = try plain(header, limit: 128) }
            case "grpc-opts":
                guard try fields["network"]?.text == "grpc" else { throw ConfigurationValidationError.invalid }
                let grpc = try value.object(required: ["grpc-service-name"])
                _ = try plain(grpc["grpc-service-name"]!)
            case "reality-opts":
                let reality = try value.object(required: ["public-key"], optional: ["short-id"])
                for entry in reality.values { _ = try plain(entry, limit: 256) }
            case "headers": try validateHeaders(value)
            case "alpn":
                let protocols = try value.list
                guard protocols.count <= 16 else { throw ConfigurationValidationError.invalid }
                for entry in protocols { _ = try plain(entry, limit: 255) }
            default:
                let text = try plain(value)
                if required.contains(key) && text.isEmpty { throw ConfigurationValidationError.invalid }
            }
        }
        return name
    }

    private static func validateHeaders(_ value: Value) throws {
        guard case .object(let headers) = value, headers.count <= 32 else { throw ConfigurationValidationError.invalid }
        for (key, item) in headers {
            guard !key.isEmpty, key.utf8.count <= 128, key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { throw ConfigurationValidationError.invalid }
            _ = try plain(item)
        }
    }
}

public struct ChainImportValidationError: LocalizedError {
    let position: Int
    public var errorDescription: String? { "第 \(position) 个节点的协议或字段不受当前 Mac 版本支持，请检查节点配置。" }
}
