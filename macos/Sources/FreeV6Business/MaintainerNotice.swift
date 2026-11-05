import Foundation

public struct MaintainerNotice: Decodable, Sendable {
    public enum Source: String, Decodable, Sendable { case online, cache, unavailable }
    public struct Item: Decodable, Identifiable, Sendable {
        public enum Level: String, Decodable, Sendable { case info, warning, critical }
        public let id, title, published: String
        public let body, link, linkText: String?
        public let level: Level
        public var detailURL: URL? {
            guard let link, let url = URL(string: link), url.scheme == "https", url.host?.isEmpty == false else { return nil }
            return url
        }
    }
    public let source: Source
    public let fetchedAt: String?
    public let items: [Item]
    public let cloudAllowed: Bool

    func validated() throws -> Self {
        guard items.count <= 20, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 120 && !$0.title.isEmpty &&
                  $0.title.unicodeScalars.count <= 201 && ($0.body?.unicodeScalars.count ?? 0) <= 4001 &&
                  ($0.link == nil || $0.detailURL != nil) }),
              source == .unavailable ? (fetchedAt == nil && items.isEmpty && !cloudAllowed)
                  : fetchedAt.flatMap(ISO8601DateFormatter().date(from:)) != nil else { throw WorkerClientError.invalidResponse }
        return self
    }
}
