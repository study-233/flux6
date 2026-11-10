import CryptoKit
import Foundation
import FreeV6System

public struct DesktopNodeGroup: Identifiable, Equatable {
    public enum Source { case session, configuration, previousSession }
    public let group: SessionNodeGroup
    public let automatic: Bool
    public let members: [String]
    public let preferred: String?
    public let selected: String?
    public let source: Source
    public var id: SessionNodeGroup { group }
    public var chosen: String? { source == .session && !automatic ? selected : preferred }

    public init(session: SessionNodeList) {
        group = session.group; automatic = session.automatic; members = session.members
        preferred = session.preferred; selected = session.selected; source = .session
    }

    init(group: SessionNodeGroup, members: [String], preferred: String?, source: Source) {
        self.group = group; self.members = members; self.preferred = preferred
        automatic = group == .access; selected = nil; self.source = source
    }

    /// Display names emitted by mihomo/config.go endpointName. The configuration fixture test guards their order and spelling.
    public static let warpNames = ["103-1", "103-2", "104-1", "104-2"].flatMap { prefix in
        [443, 500, 1701, 4500, 4443, 8443, 8095].map { "\(prefix)-\($0)" }
    }
}

struct NodePreferenceStore {
    private let defaults: UserDefaults
    private let catalogKey = "nodeCatalog.names.v1"
    private let automatic = "auto"

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
        for group in SessionNodeGroup.allCases {
            let oldPreference = "preferredNode." + group.rawValue
            if let name = defaults.string(forKey: oldPreference) {
                defaults.set(Self.digest(name), forKey: preferenceKey(group))
                defaults.removeObject(forKey: oldPreference)
            }
            let oldRecent = "recentNodes." + group.rawValue
            if let names = defaults.stringArray(forKey: oldRecent) {
                defaults.set(names.prefix(5).map(Self.digest), forKey: recentKey(group))
                defaults.removeObject(forKey: oldRecent)
            }
        }
    }

    private static func digest(_ name: String) -> String {
        Data(SHA256.hash(data: Data(name.utf8))).base64EncodedString()
    }
    private func preferenceKey(_ group: SessionNodeGroup) -> String { "nodePreference.v2." + group.rawValue }
    private func recentKey(_ group: SessionNodeGroup) -> String { "nodeRecents.v2." + group.rawValue }
    func hasPreference(_ group: SessionNodeGroup) -> Bool { defaults.string(forKey: preferenceKey(group)) != nil }
    func wantsAutomatic(_ group: SessionNodeGroup) -> Bool { defaults.string(forKey: preferenceKey(group)) == automatic }
    func forget(_ group: SessionNodeGroup) { defaults.removeObject(forKey: preferenceKey(group)) }

    func choose(_ name: String?, group: SessionNodeGroup) {
        guard let name else {
            if group == .access { defaults.set(automatic, forKey: preferenceKey(group)) } else { forget(group) }
            return
        }
        let key = Self.digest(name)
        defaults.set(key, forKey: preferenceKey(group))
        let recent = [key] + (defaults.stringArray(forKey: recentKey(group)) ?? []).filter { $0 != key }
        defaults.set(Array(recent.prefix(5)), forKey: recentKey(group))
    }

    func preferred(_ group: SessionNodeGroup, in names: [String]) -> String? {
        guard let key = defaults.string(forKey: preferenceKey(group)), key != automatic else { return nil }
        return names.first { Self.digest($0) == key }
    }

    func recent(_ group: SessionNodeGroup, in names: [String]) -> [String] {
        let keys = defaults.stringArray(forKey: recentKey(group)) ?? []
        guard !keys.isEmpty else { return [] }
        let lookup = Dictionary(names.map { (Self.digest($0), $0) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { lookup[$0] }
    }

    // Keep only display aliases in the last-session cache. A preference/recent entry uses a digest,
    // so even labels resembling an address or credential can be selected from a fresh configuration.
    private static func cacheableAlias(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              name.range(of: #"[.:/@?#=%&\\]|[A-Za-z0-9_\-]{24,}"#, options: .regularExpression) == nil else { return false }
        return true
    }

    func remember(_ groups: [SessionNodeList]) -> Bool {
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.group.rawValue, $0.members.filter(Self.cacheableAlias)) })
        if (defaults.dictionary(forKey: catalogKey) as? [String: [String]]) == names { return false }
        defaults.set(names, forKey: catalogKey)
        return true
    }

    var previous: [String: [String]] { defaults.dictionary(forKey: catalogKey) as? [String: [String]] ?? [:] }
}
