import Foundation
import FreeV6Configuration

public enum ProxyRuleField: Hashable, Sendable {
    case campus, blacklist

    public var title: String { self == .campus ? "校园白名单" : "黑名单" }
}

public struct ProxyRuleIssue: Identifiable, Sendable {
    public let id = UUID()
    public let field: ProxyRuleField
    public let line: Int
    public let range: NSRange
    public let reason: String
    public var message: String { "\(field.title)第 \(line) 行：\(reason)" }

    /// Locate a rejected worker entry in the original editor text, including blank lines and CRLF.
    /// The worker remains authoritative for saving and for errors unrelated to either list.
    public static func locate(in text: String, field: ProxyRuleField) -> Self? {
        var count = 0
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let entry = line.trimmingCharacters(in: .whitespaces).lowercased()
            if entry.isEmpty { continue }
            count += 1
            let reason: String
            if count > 2_048 { reason = "每份名单最多填写 2,048 条。" }
            else if entry.utf8.count > 1_024 { reason = "每条规则最多 1,024 字节。" }
            else if entry.contains("://") { reason = "请移除网址协议和路径，只填写域名，例如 edu.cn。" }
            else if field == .campus && !ProxyRuleSyntax.isCampusEntry(entry) {
                reason = "请输入域名或完整 CIDR 网段，例如 edu.cn 或 202.204.0.0/12。"
            } else if field == .blacklist && !ProxyRuleSyntax.isDomain(entry) {
                reason = "请输入域名，例如 example.org。每行填写一个。"
            } else { continue }
            return Self(field: field, line: index + 1, range: NSRange(line.startIndex..<line.endIndex, in: text), reason: reason)
        }
        return nil
    }
}
