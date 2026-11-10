import Darwin
import Foundation

public enum ProxyRuleSyntax {
    public static func isDomain(_ value: String) -> Bool {
        guard value.utf8.count <= 253, value.contains(".") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    public static func isCampusEntry(_ value: String) -> Bool {
        guard value.contains("/") else { return isDomain(value) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].utf8.contains(0),
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }), let bits = Int(parts[1]) else { return false }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, String(parts[0]), &ipv4) == 1 { return (0...32).contains(bits) }
        var ipv6 = in6_addr()
        return (0...128).contains(bits) && inet_pton(AF_INET6, String(parts[0]), &ipv6) == 1
    }
}
