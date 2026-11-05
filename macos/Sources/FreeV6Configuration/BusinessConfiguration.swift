import Darwin
import Foundation

// A bounded JSON tree preserves the Go renderer's business output without
// passing arbitrary core configuration to the privileged side. No file I/O.
indirect enum Value: Codable, Sendable {
    case string(String), number(Double), bool(Bool), array([Value]), object([String: Value])
    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 12 else { throw ConfigurationValidationError.invalid }
        let value = try decoder.singleValueContainer()
        if let b = try? value.decode(Bool.self) { self = .bool(b) }
        else if let n = try? value.decode(Double.self), n.isFinite { self = .number(n) }
        else if let s = try? value.decode(String.self), s.utf8.count <= 8192 { self = .string(s) }
        else if let a = try? value.decode([Value].self), a.count <= 6000 { self = .array(a) }
        else if let o = try? value.decode([String: Value].self), o.count <= 256 { self = .object(o) }
        else { throw ConfigurationValidationError.invalid }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    func object(required: Set<String>, optional: Set<String> = []) throws -> [String: Value] {
        guard case .object(let object) = self, required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else { throw ConfigurationValidationError.invalid }
        return object
    }
    var list: [Value] { get throws { guard case .array(let a) = self else { throw ConfigurationValidationError.invalid }; return a } }
    var text: String { get throws { guard case .string(let s) = self else { throw ConfigurationValidationError.invalid }; return s } }
    func number(in range: ClosedRange<Double>) throws -> Double {
        guard case .number(let n) = self, n.rounded() == n, range.contains(n) else { throw ConfigurationValidationError.invalid }; return n
    }
    func boolean(_ expected: Bool? = nil) throws {
        guard case .bool(let b) = self, expected == nil || b == expected else { throw ConfigurationValidationError.invalid }
    }
}

public struct BusinessConfiguration: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: Value
    public let mode: String
    public let proxyCount: Int
    public let ruleCount: Int
    public var description: String { "BusinessConfiguration(redacted)" }
    public var debugDescription: String { description }

    public init(from decoder: Decoder) throws {
        do {
            let value = try Value(from: decoder)
            let object = try value.object(required: ["mode", "proxies", "proxy-groups", "rule-providers", "rules"])
            mode = try object["mode"]!.text
            guard ["rule", "global", "direct"].contains(mode) else { throw ConfigurationValidationError.invalid }
            proxyCount = try object["proxies"]!.list.count
            ruleCount = try object["rules"]!.list.count
            self.value = value
            try validate(object)
            guard try encoded().count <= 512 * 1024 else { throw ConfigurationValidationError.invalid }
        } catch { throw ConfigurationValidationError.invalid }
    }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    public func encoded() throws -> Data { try JSONEncoder().encode(value) }

    public func requireWarp(_ tunnel: TunnelCredential, mode: String, chainNames: [String] = []) throws {
        let tunnel = try tunnel.validated()
        guard self.mode == mode, proxyCount == 28 + chainNames.count, case .object(let object) = value else { throw ConfigurationValidationError.incompatible }
        let proxies = try object["proxies"]!.list
        let imported = try proxies.dropFirst(28).map { try ImportedChainNodes.name(of: $0) }
        guard imported == chainNames else { throw ConfigurationValidationError.incompatible }
        for proxy in proxies.prefix(28) {
            let fields = try proxy.object(required: Self.proxyFields)
            guard try fields["private-key"]!.text == tunnel.privateKey, try fields["public-key"]!.text == tunnel.peerPublicKey,
                  try fields["ip"]!.text == tunnel.ipv4, try fields["ipv6"]!.text == tunnel.ipv6 else { throw ConfigurationValidationError.incompatible }
        }
    }

    private static let proxyFields: Set<String> = ["name", "type", "server", "port", "private-key", "public-key", "ip", "ipv6", "mtu", "udp", "remote-dns-resolve", "dns"]
    private func validate(_ object: [String: Value]) throws {
        let proxies = try object["proxies"]!.list
        guard !proxies.isEmpty, proxies.count <= 28 + ImportedChainNodes.limit else { throw ConfigurationValidationError.invalid }
        var names: Set<String> = ["DIRECT", "REJECT", "PASS", "COMPATIBLE"]
        var warpNames: [String] = [], importedNames: [String] = []
        for proxy in proxies {
            guard case .object(let fields) = proxy else { throw ConfigurationValidationError.invalid }
            if try fields["type"]?.text != "masque" {
                let name = try ImportedChainNodes.name(of: proxy)
                guard warpNames.count == 28, names.insert(name).inserted else { throw ConfigurationValidationError.invalid }
                importedNames.append(name)
                continue
            }
            guard importedNames.isEmpty, warpNames.count < 28 else { throw ConfigurationValidationError.invalid }
            let p = try proxy.object(required: Self.proxyFields)
            let name = try p["name"]!.text
            guard validName(name), names.insert(name).inserted, try p["type"]!.text == "masque" else { throw ConfigurationValidationError.invalid }
            warpNames.append(name)
            let server = try p["server"]!.text
            guard validIPAddress(server, family: AF_INET) || validIPAddress(server, family: AF_INET6) else { throw ConfigurationValidationError.invalid }
            _ = try p["port"]!.number(in: 1...65535)
            _ = try p["mtu"]!.number(in: 1280...1500)
            try p["udp"]!.boolean(true); try p["remote-dns-resolve"]!.boolean(true)
            _ = try TunnelCredential(privateKey: p["private-key"]!.text, peerPublicKey: p["public-key"]!.text,
                                     ipv4: p["ip"]!.text, ipv6: p["ipv6"]!.text).validated()
            let dns = try p["dns"]!.list
            guard !dns.isEmpty, dns.count <= 8 else { throw ConfigurationValidationError.invalid }
            for address in dns {
                let text = try address.text
                guard validIPAddress(text, family: AF_INET) || validIPAddress(text, family: AF_INET6) else { throw ConfigurationValidationError.invalid }
            }
        }
        let groups = try object["proxy-groups"]!.list
        guard !groups.isEmpty, groups.count <= 32 else { throw ConfigurationValidationError.invalid }
        var references: [String: [String]] = [:]
        var groupTypes: [String: String] = [:]
        for group in groups {
            let g = try group.object(required: ["name", "type", "proxies"], optional: ["url", "interval", "tolerance", "lazy"])
            let name = try g["name"]!.text, type = try g["type"]!.text
            guard validName(name), names.insert(name).inserted, ["select", "url-test", "fallback"].contains(type) else { throw ConfigurationValidationError.invalid }
            let members = try g["proxies"]!.list.map { try $0.text }
            guard !members.isEmpty, members.count <= 64, Set(members).count == members.count else { throw ConfigurationValidationError.invalid }
            if type == "select" {
                guard g.count == 3 else { throw ConfigurationValidationError.invalid }
            } else {
                guard try g["url"]?.text == "http://www.gstatic.com/generate_204", let interval = g["interval"] else { throw ConfigurationValidationError.invalid }
                _ = try interval.number(in: 60...86400)
                if let tolerance = g["tolerance"] { _ = try tolerance.number(in: 0...10000) }
                if let lazy = g["lazy"] { try lazy.boolean() }
            }
            references[name] = members
            groupTypes[name] = type
        }
        var visiting: Set<String> = [], visited: Set<String> = []
        func visit(_ name: String) throws {
            guard names.contains(name), !visiting.contains(name) else { throw ConfigurationValidationError.invalid }
            if visited.contains(name) { return }
            visiting.insert(name)
            for member in references[name] ?? [] { try visit(member) }
            visiting.remove(name); visited.insert(name)
        }
        for name in references.keys { try visit(name) }
        guard case .object(let providers) = object["rule-providers"], providers.count <= 32 else { throw ConfigurationValidationError.invalid }
        for (name, value) in providers {
            let p = try value.object(required: ["type", "behavior", "format", "interval", "url", "path"])
            guard name.count == 6, name.hasPrefix("rule"), name.suffix(2).utf8.allSatisfy({ (48...57).contains($0) }),
                  try p["type"]!.text == "http", try p["behavior"]!.text == "classical", try p["format"]!.text == "text",
                  try p["path"]!.text == "./ruleset/\(name).list", try Self.providerURLs.contains(p["url"]!.text) else { throw ConfigurationValidationError.invalid }
            _ = try p["interval"]!.number(in: 3600...604800)
        }
        let rules = try object["rules"]!.list.map { try $0.text }
        guard !rules.isEmpty, rules.count <= 6000 else { throw ConfigurationValidationError.invalid }
        let chainGroup = "🔗 链式代理"
        if importedNames.isEmpty {
            guard references[chainGroup] == nil, rules.last?.hasPrefix("MATCH,") == true else { throw ConfigurationValidationError.invalid }
        } else {
            let access = ["♻️ 自动选择", "🔄 故障转移", "☑️ 手动切换"]
            guard references[chainGroup] == importedNames, groupTypes[chainGroup] == "select",
                  references["🚀 节点选择"] == access, groupTypes["🚀 节点选择"] == "select",
                  access.allSatisfy({ references[$0] == warpNames }),
                  references["GLOBAL"] == [chainGroup], groupTypes["GLOBAL"] == "select", providers.isEmpty,
                  Array(rules.suffix(2)) == ["MATCH," + chainGroup, "NETWORK,UDP,REJECT"] else { throw ConfigurationValidationError.invalid }
        }
        var matches = 0
        for (index, rule) in rules.enumerated() {
            guard rule.utf8.count <= 1024 else { throw ConfigurationValidationError.invalid }
            let parts = rule.components(separatedBy: ",")
            switch parts.first {
            case "DOMAIN-SUFFIX":
                guard parts.count == 3, validDomain(parts[1]), ["DIRECT", "REJECT"].contains(parts[2]) else { throw ConfigurationValidationError.invalid }
            case "IP-CIDR", "IP-CIDR6":
                guard parts.count == 4, parts[2] == "DIRECT", parts[3] == "no-resolve" else { throw ConfigurationValidationError.invalid }
                let cidr = parts[1].split(separator: "/", omittingEmptySubsequences: false)
                let v4 = parts[0] == "IP-CIDR"
                guard cidr.count == 2, let bits = Int(cidr[1]), (0...(v4 ? 32 : 128)).contains(bits),
                      validIPAddress(String(cidr[0]), family: v4 ? AF_INET : AF_INET6) else { throw ConfigurationValidationError.invalid }
            case "RULE-SET":
                guard parts.count == 3, providers[parts[1]] != nil, references[parts[2]] != nil else { throw ConfigurationValidationError.invalid }
            case "GEOIP":
                guard parts == ["GEOIP", "LAN", "DIRECT", "no-resolve"] else { throw ConfigurationValidationError.invalid }
            case "NETWORK":
                guard !importedNames.isEmpty, index == rules.count - 1, parts == ["NETWORK","UDP","REJECT"] else { throw ConfigurationValidationError.invalid }
            case "MATCH":
                matches += 1
                guard parts.count == 2, references[parts[1]] != nil else { throw ConfigurationValidationError.invalid }
            default: throw ConfigurationValidationError.invalid
            }
        }
        guard matches == 1 else { throw ConfigurationValidationError.invalid }
    }

    private func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private func validDomain(_ value: String) -> Bool {
        guard value.utf8.count <= 253, value.contains(".") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    private static let providerURLs: Set<String> = [
        "https://raw.githubusercontent.com/cmliu/ACL4SSR/refs/heads/main/Clash/CFnat.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/LocalAreaNetwork.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/UnBan.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanAD.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/GoogleCN.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/SteamCN.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ProxyLite.list",
        "https://raw.githubusercontent.com/cmliu/ACL4SSR/main/Clash/CMBlog.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ChinaDomain.list",
        "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ChinaCompanyIp.list",
    ]
}
