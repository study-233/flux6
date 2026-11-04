import Foundation
import SystemConfiguration

/// Captures configured DNS, preserving an absent dictionary (DHCP/system
/// managed) separately from manually configured resolver values.
public struct DNSServiceSnapshot: Codable, Equatable {
    public let serviceID: String
    public let name: String
    public let enabled: Bool
    public let configuredDNS: Data?

}

public enum DNSConfiguration {
    public static func capture() throws -> [DNSServiceSnapshot] {
        guard let preferences = SCPreferencesCreate(nil, "FreeV6 DNS snapshot" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            throw DNSConfigurationError.readFailed(SCError())
        }
        return try services.map { service in
            guard let serviceID = SCNetworkServiceGetServiceID(service) else {
                throw DNSConfigurationError.readFailed(SCError())
            }
            var data: Data?
            if let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS),
               let configuration = SCNetworkProtocolGetConfiguration(dns) {
                data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
            }
            return DNSServiceSnapshot(
                serviceID: serviceID as String,
                name: (SCNetworkServiceGetName(service) as String?) ?? "",
                enabled: SCNetworkServiceGetEnabled(service),
                configuredDNS: data
            )
        }.sorted { $0.serviceID < $1.serviceID }
    }
}

public enum DNSConfigurationError: Error {
    case readFailed(Int32)
}
