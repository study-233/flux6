import Darwin
import Foundation

/// The same public IPv6 echo and two /32 networks used by the Windows client.
public enum CampusIPv6 {
    private static let echo = URL(string: "https://api-ipv6.ip.sb/ip")!

    public static func check(developerMode: Bool) async throws {
        try await check(developerMode: developerMode) { try await readAddress(using: .ephemeral) }
    }

    static func check(developerMode: Bool, read: () async throws -> String) async throws {
        guard !developerMode else { return }
        let value = try await read().trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in6_addr()
        guard !value.utf8.contains(0), value.utf8.count < Int(INET6_ADDRSTRLEN),
              inet_pton(AF_INET6, value, &address) == 1 else { throw CampusNetworkError.invalidResponse }
        let prefix = withUnsafeBytes(of: &address) { $0.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        guard prefix == 0x20010da8 || prefix == 0x20010250 else { throw CampusNetworkError.outsideCampus }
    }

    static func readAddress(using config: URLSessionConfiguration) async throws -> String {
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: EchoOrigin(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(from: echo)
            guard let http = response as? HTTPURLResponse, http.url == echo,
                  (200..<300).contains(http.statusCode) else { throw CampusNetworkError.invalidResponse }
            var bytes = [UInt8]()
            for try await byte in stream {
                guard bytes.count < 128 else { throw CampusNetworkError.invalidResponse }
                bytes.append(byte)
            }
            guard let address = String(bytes: bytes, encoding: .ascii) else { throw CampusNetworkError.invalidResponse }
            return address
        } catch let error as CampusNetworkError { throw error }
        catch { throw CampusNetworkError.unavailable }
    }
}

private final class EchoOrigin: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CampusNetworkError: Error, Equatable, LocalizedError {
    case unavailable, invalidResponse, outsideCampus
    var errorDescription: String? {
        switch self {
        case .outsideCampus: return "当前公网 IPv6 不属于支持的校园网段，请切换校园网络后再连接。"
        case .unavailable: return "公网 IPv6 检测失败，请检查网络后重试。"
        case .invalidResponse: return "检测服务未返回有效的公网 IPv6，请检查网络后重试。"
        }
    }
}
