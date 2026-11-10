import Darwin
import Foundation
import SystemConfiguration

enum SessionDNSError: Error, Equatable, LocalizedError {
    case unavailable, busy, unsupportedNetwork, changed, invalidRecord, wrongSession, invalidPhase
    case commitFailed, applyFailed, identityChanged, resolverUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取网络服务的 DNS 配置"
        case .busy: return "系统网络设置正被其他操作占用，请稍后重试"
        case .unsupportedNetwork: return "当前主网络需要独立验证 DNS 配置"
        case .changed: return "准备期间网络或 DNS 设置发生变化，请重新检查"
        case .invalidRecord: return "DNS 恢复记录无效，已保留原始记录"
        case .wrongSession: return "DNS 操作与当前会话不匹配"
        case .invalidPhase: return "当前 DNS 事务阶段无法执行此操作"
        case .commitFailed: return "系统未确认 DNS 配置写入"
        case .applyFailed: return "系统未确认应用 DNS 配置，需要恢复"
        case .resolverUnavailable: return "核心的本地 DNS 监听或解析应答尚未通过验证"
        case .identityChanged: return "网络服务身份已变化，请检查保留的 DNS 恢复记录"
        }
    }
}

// The adapter owns the exclusive preferences lock through the compare, journal,
// commit and apply. Tests use the same SCPreferences tree with a private plist.
protocol SessionDNSPreferences {
    func withLock<T>(_ body: (SCPreferences) throws -> T) throws -> T
    func primaryServices() throws -> [String: String]
    func commit(_ preferences: SCPreferences) throws
    func apply(_ preferences: SCPreferences) throws
    func resolverReleased() throws -> Bool
}

struct SystemDNSPreferences: SessionDNSPreferences {
    func withLock<T>(_ body: (SCPreferences) throws -> T) throws -> T {
        guard geteuid() == 0 else { throw SessionDNSError.wrongSession }
        _ = try ServiceProcessOrigin.current()
        guard let prefs = SCPreferencesCreate(nil, "FreeV6 network session" as CFString, nil) else {
            throw SessionDNSError.unavailable
        }
        guard SCPreferencesLock(prefs, false) else {
            throw SCError() == kSCStatusPrefsBusy ? SessionDNSError.busy : .unavailable
        }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        return try body(prefs)
    }

    func primaryServices() throws -> [String: String] {
        guard let store = SCDynamicStoreCreate(nil, "FreeV6 primary network" as CFString, nil, nil) else {
            throw SessionDNSError.unavailable
        }
        let keys = [kSCEntNetIPv4, kSCEntNetIPv6].map {
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, $0) as String
        }
        guard let values = SCDynamicStoreCopyMultiple(store, keys as CFArray, nil) as? [String: Any] else {
            throw SessionDNSError.unavailable
        }
        var primary: [String: String] = [:]
        for key in keys {
            guard let value = values[key] else { continue }
            guard let info = value as? [String: Any] else { throw SessionDNSError.unavailable }
            if info[kSCDynamicStorePropNetPrimaryService as String] == nil,
               info[kSCDynamicStorePropNetPrimaryInterface as String] == nil { continue }
            guard let id = info[kSCDynamicStorePropNetPrimaryService as String] as? String,
                  let device = info[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
                  primary[id] == nil || primary[id] == device else { throw SessionDNSError.unsupportedNetwork }
            primary[id] = device
        }
        return primary
    }

    func commit(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences) else { throw SessionDNSError.commitFailed }
    }

    func apply(_ preferences: SCPreferences) throws {
        guard SCPreferencesApplyChanges(preferences) else { throw SessionDNSError.applyFailed }
    }

    /// Inspect configd's published setup and state, including per-service
    /// entries. An empty or inaccessible store is not evidence of removal.
    func resolverReleased() throws -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "FreeV6 DNS activation" as CFString, nil, nil) else {
            throw SessionDNSError.unavailable
        }
        let root = (kSCDynamicStoreDomainSetup as String) + "/"
        let domains = [kSCDynamicStoreDomainSetup, kSCDynamicStoreDomainState]
        let globals = domains.map { SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, $0, kSCEntNetDNS) as String }
        let servicePatterns = domains.map {
            SCDynamicStoreKeyCreateNetworkServiceEntity(nil, $0, kSCCompAnyRegex, kSCEntNetDNS) as String
        }
        guard let values = SCDynamicStoreCopyMultiple(store, ([root] + globals) as CFArray, servicePatterns as CFArray) as? [String: Any],
              values[root] is [String: Any] else { throw SessionDNSError.unavailable }
        for (key, value) in values where key != root {
            guard let dns = value as? [String: Any] else { throw SessionDNSError.unavailable }
            if try DNSResolverPolicy.referencesEndpoint(dns) { return false }
        }
        return true
    }
}

enum DNSResolverPolicy {
    static let address = "127.0.0.1"
    static let port = 1053
    static let listener = "\(address):\(port)"
    static let checkAnswer = "192.0.2.1"
    static func checkName(_ sessionID: UUID) -> String { "freev6-" + sessionID.uuidString.lowercased() + ".test" }
    static func hostsPattern(_ sessionID: UUID) -> String { "+." + checkName(sessionID) }
    static func freshName(_ sessionID: UUID) -> String { UUID().uuidString.lowercased() + "." + checkName(sessionID) }
    static let addressesKey = kSCPropNetDNSServerAddresses as String
    static let portKey = kSCPropNetDNSServerPort as String

    static func configured(_ original: [String: Any]?) -> [String: Any] {
        var result = original ?? [:]
        result[addressesKey] = [address]
        result[portKey] = port
        return result
    }

    static func resolverFields(_ dictionary: [String: Any]?) -> NSDictionary {
        (dictionary ?? [:]).filter { $0.key == addressesKey || $0.key == portKey } as NSDictionary
    }

    static func referencesEndpoint(_ dictionary: [String: Any]?) throws -> Bool {
        guard let value = dictionary?[addressesKey] else { return false }
        guard let addresses = value as? [String] else { throw SessionDNSError.unavailable }
        guard addresses.contains(address), let number = dictionary?[portKey] else { return false }
        guard let resolverPort = number as? Int else { throw SessionDNSError.unavailable }
        return resolverPort == port
    }

    static func validDevice(_ name: String) -> Bool {
        let suffix = name.utf8.dropFirst(2)
        return name.hasPrefix("en") && (1...8).contains(suffix.count) && suffix.allSatisfy { (48...57).contains($0) }
    }
}

struct DNSNetworkService {
    let type: String?
    let device: String?
    let hardware: String?
    let dns: [String: Any]?

    static func services(_ prefs: SCPreferences) throws -> [String: Any] {
        guard let services = SCPreferencesGetValue(prefs, kSCPrefNetworkServices) as? [String: Any] else {
            throw SessionDNSError.unavailable
        }
        return services
    }

    static func read(_ id: String, from services: [String: Any]) throws -> Self? {
        guard let value = services[id] else { return nil }
        guard let service = value as? [String: Any], service[kSCResvLink as String] == nil else {
            throw SessionDNSError.unavailable
        }
        let interface = service[kSCEntNetInterface as String] as? [String: Any]
        var dns: [String: Any]?
        if let value = service[kSCEntNetDNS as String] {
            guard let config = value as? [String: Any], config[kSCResvLink as String] == nil else {
                throw SessionDNSError.unavailable
            }
            dns = config
        }
        return Self(type: interface?[kSCPropNetInterfaceType as String] as? String,
                    device: interface?[kSCPropNetInterfaceDeviceName as String] as? String,
                    hardware: interface?[kSCPropNetInterfaceHardware as String] as? String, dns: dns)
    }

    // Read the configured DNS entity directly to preserve absent vs. empty.
    // All paths use a service UUID validated both at discovery and on recovery.
    static func write(_ dns: [String: Any]?, id: String, in prefs: SCPreferences) throws {
        guard UUID(uuidString: id) != nil else { throw SessionDNSError.invalidRecord }
        let path = "/\(kSCPrefNetworkServices)/\(id)/\(kSCEntNetDNS)" as CFString
        let ok: Bool
        if let dns { ok = SCPreferencesPathSetValue(prefs, path, dns as CFDictionary) }
        else { ok = SCPreferencesPathRemoveValue(prefs, path) }
        guard ok else { throw SessionDNSError.commitFailed }
    }
}
