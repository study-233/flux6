import Foundation
import Security
import FreeV6Configuration

public struct ConfigurationCheckRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let protocolVersion: Int
    public let requestID: UUID
    public let runtimeID: String
    public let geodataID: String
    public let settingsRevision: UInt64
    public let credentialRevision: UUID
    public let profileSource: String?
    public let configuration: BusinessConfiguration
    public var description: String { "ConfigurationCheckRequest(redacted)" }
    public var debugDescription: String { description }

    public init(runtimeID: String, geodataID: String, settingsRevision: UInt64, credentialRevision: UUID,
                configuration: BusinessConfiguration) {
        protocolVersion = ServiceProtocolVersion.current; requestID = UUID()
        self.runtimeID = runtimeID; self.geodataID = geodataID; self.settingsRevision = settingsRevision
        self.profileSource = configuration.isCampusProfile ? "cloud" : nil
        self.credentialRevision = credentialRevision; self.configuration = configuration
    }
}

public struct ConfigurationCheckReply: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let policyVersion: Int
    public let settingsRevision: UInt64
    public let credentialRevision: UUID
    public let mode: String
    public let proxyCount: Int
    public let ruleCount: Int
    public let coreValidated: Bool
    init(_ request: ConfigurationCheckRequest) {
        protocolVersion = ServiceProtocolVersion.current; requestID = request.requestID
        policyVersion = ServiceConfigurationAssembler.policyVersion
        settingsRevision = request.settingsRevision; credentialRevision = request.credentialRevision
        mode = request.configuration.mode; proxyCount = request.configuration.proxyCount; ruleCount = request.configuration.ruleCount
        coreValidated = true
    }
}

extension ServiceMessages {
    public static var maximumConfigurationBytes: Int { 512 * 1024 + 4096 }
    public static func decodeConfiguration(_ data: Data) throws -> ConfigurationCheckRequest {
        guard data.count <= maximumConfigurationBytes else { throw ServiceMessageError.oversized }
        let fields: Set<String> = ["protocolVersion", "requestID", "runtimeID", "geodataID", "settingsRevision", "credentialRevision", "configuration"]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == fields || Set(object.keys) == fields.union(["profileSource"]) else {
                throw ServiceMessageError.invalid
            }
            let request = try JSONDecoder().decode(ConfigurationCheckRequest.self, from: data)
            guard request.protocolVersion == ServiceProtocolVersion.current else {
                throw ServiceMessageError.incompatibleVersion(request.protocolVersion)
            }
            if request.configuration.isCampusProfile {
                guard request.profileSource == "cloud" else { throw ServiceMessageError.invalid }
            } else if object["profileSource"] != nil { throw ServiceMessageError.invalid }
            try ApprovedResourceCatalog.requirePair(runtimeID: request.runtimeID, geodataID: request.geodataID)
            return request
        } catch let error as ServiceMessageError { throw error }
        catch let error as ResourceStoreError { throw error }
        catch { throw ServiceMessageError.invalid } // Never expose credential-bearing decoder details.
    }
}

public struct AssembledServiceConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public let data: Data
    public var description: String { "AssembledServiceConfiguration(redacted)" }
    public var debugDescription: String { description }
}

/// System policy is owned by the service. This function only assembles bytes;
/// it never starts the core, creates a session directory or alters networking.
public enum ServiceConfigurationAssembler {
    public static let policyVersion = 2
    public static let sessions = "/Library/Application Support/dev.freev6.desktop/sessions"

    public static func assemble(_ business: BusinessConfiguration, sessionID: UUID) throws -> AssembledServiceConfiguration {
        try assemble(business, sessionID: sessionID, sessionsDirectory: sessions)
    }

    // The store supplies its validated directory; never decode this from IPC.
    static func assemble(_ business: BusinessConfiguration, sessionID: UUID, sessionsDirectory: String) throws -> AssembledServiceConfiguration {
        let socket = sessionsDirectory + "/" + sessionID.uuidString + "/c.sock"
        // Darwin sockaddr_un.sun_path is 104 bytes including the terminator.
        guard socket.utf8.count < 104 else { throw ServiceMessageError.invalid }
        var secret = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else { throw ResourceStoreError.io }
        guard var document = try JSONSerialization.jsonObject(with: business.encoded()) as? [String: Any] else {
            throw ServiceMessageError.invalid
        }
        let chinaDNS = ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query", "2400:3200::1", "2400:3200:baba::1"]
        let foreignDNS = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "2606:4700:4700::1111", "2606:4700:4700::1001"]
        var geox: [String: String] = [:]
        for asset in ApprovedResourceCatalog.native where asset.architecture == nil {
            let parts = asset.id.split(separator: "/")
            let revision = String(parts[0].dropFirst(8)), name = String(parts[1])
            let key = name == "GeoSite.dat" ? "geosite" : name == "geoip.dat" ? "geoip" : "mmdb"
            geox[key] = "https://v6.gh-proxy.org/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/\(revision)/\(name.lowercased())"
        }
        let system: [String: Any] = [
            "mixed-port": 7890, "allow-lan": false, "bind-address": "127.0.0.1",
            "ipv6": true, "log-level": "error", "find-process-mode": "always",
            "tcp-concurrent": true, "unified-delay": true,
            "external-controller": "", "external-controller-tls": "", "external-controller-unix": socket,
            "secret": secret.map { String(format: "%02x", $0) }.joined(),
            "external-ui": "", "external-ui-url": "",
            "geo-auto-update": false, "geox-url": geox,
            "profile": ["store-fake-ip": true, "store-selected": true],
            "tun": ["enable": true, "stack": "mixed", "auto-route": true,
                    "auto-detect-interface": true, "dns-hijack": ["any:53", "tcp://any:53"]],
            "hosts": [DNSResolverPolicy.hostsPattern(sessionID): DNSResolverPolicy.checkAnswer],
            "dns": ["enable": true, "use-hosts": true, "ipv6": true, "listen": DNSResolverPolicy.listener, "enhanced-mode": "fake-ip",
                    "fake-ip-range": "198.18.0.1/16",
                    "fake-ip-filter": [DNSResolverPolicy.hostsPattern(sessionID), "+.lan", "+.local", "*.msftconnecttest.com", "*.msftncsi.com"],
                    "default-nameserver": ["223.5.5.5", "119.29.29.29", "2606:4700:4700::1111", "2606:4700:4700::1001", "2400:3200::1", "2400:3200:baba::1"],
                    "nameserver": ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query", "2606:4700:4700::1111", "2606:4700:4700::1001", "2400:3200::1", "2400:3200:baba::1"],
                    "nameserver-policy": ["geosite:cn,private": chinaDNS, "geosite:geolocation-!cn": foreignDNS],
                    "proxy-server-nameserver": ["https://223.5.5.5/dns-query", "2606:4700:4700::1111", "2400:3200::1"]],
            "sniffer": ["enable": true, "skip-domain": ["+.push.apple.com", "+.apple.com"],
                        "sniff": ["HTTP": ["ports": [80, "8080-8880"], "override-destination": true],
                                  "TLS": ["ports": [443, 8443]], "QUIC": ["ports": [443, 8443]]]],
        ]
        // BusinessConfiguration's strict decoder rejects every system key.
        guard Set(document.keys).isDisjoint(with: Set(system.keys)) else { throw ServiceMessageError.invalid }
        document.merge(system) { _, _ in preconditionFailure("System key collision") }
        let encoded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= ServiceMessages.maximumConfigurationBytes else { throw ServiceMessageError.oversized }
        return AssembledServiceConfiguration(data: encoded)
    }
}
