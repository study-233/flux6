import Foundation
import FreeV6Configuration

public struct PreparedConfiguration: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let schemaVersion: Int
    public let settingsRevision: UInt64
    public let credentialRevision: UUID
    public let runtimeId: String
    public let geodataId: String
    public let configuration: BusinessConfiguration
    public var description: String { "PreparedConfiguration(redacted)" }
    public var debugDescription: String { description }

    func validated(settings: SettingsSnapshot, revision: UUID, tunnel: TunnelCredential, runtimeId: String, geodataId: String) throws -> Self {
        guard schemaVersion == 1, settingsRevision == settings.revision, credentialRevision == revision,
              self.runtimeId == runtimeId, self.geodataId == geodataId else { throw ConfigurationValidationError.incompatible }
        let chainNames = settings.chain.flatMap { $0.enabled ? $0.names : nil } ?? []
        try configuration.requireWarp(tunnel, mode: settings.settings.mode.rawValue, chainNames: chainNames)
        return self
    }
}

public struct ConfigurationSummary: Sendable {
    public let settingsRevision: UInt64
    public let credentialRevision: UUID
    public let mode: String
    public let proxyCount: Int
    public let ruleCount: Int
    public init(_ prepared: PreparedConfiguration) {
        settingsRevision = prepared.settingsRevision; credentialRevision = prepared.credentialRevision
        mode = prepared.configuration.mode; proxyCount = prepared.configuration.proxyCount; ruleCount = prepared.configuration.ruleCount
    }
}
