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
        let configuredServices = try DNSNetworkService.services(preferences)
        return try services.map { service in
            guard let serviceID = SCNetworkServiceGetServiceID(service) else {
                throw DNSConfigurationError.readFailed(SCError())
            }
            guard let raw = try DNSNetworkService.read(serviceID as String, from: configuredServices) else {
                throw SessionDNSError.unavailable
            }
            let data = try raw.dns.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
            return DNSServiceSnapshot(
                serviceID: serviceID as String,
                name: (SCNetworkServiceGetName(service) as String?) ?? "",
                enabled: SCNetworkServiceGetEnabled(service),
                configuredDNS: data
            )
        }.sorted { $0.serviceID < $1.serviceID }
    }
    /// Read-only diagnostic. No lock, commit, apply, resolver address or service
    /// name is exposed by the probe.
    public static func previewTargets() throws -> (count: Int, endpointInUse: Bool) {
        guard let prefs = SCPreferencesCreate(nil, "FreeV6 DNS preview" as CFString, nil) else { throw SessionDNSError.unavailable }
        let access = SystemDNSPreferences()
        let count = try SessionDNSTransaction.targets(in: prefs, primary: access.primaryServices()).1.count
        return (count, try !access.resolverReleased())
    }
}

public enum DNSConfigurationError: Error {
    case readFailed(Int32)
}
