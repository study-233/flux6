import Darwin
import Foundation
import FreeV6Business
import FreeV6Desktop
import FreeV6System

struct HostFailure: LocalizedError {
    let code: String
    let errorDescription: String?
    init(_ code: String, _ message: String) { self.code = code; self.errorDescription = message }
}

protocol HostSession: Actor {
    func health() throws -> DesktopServiceState
    func status(_ id: UUID?) throws -> NetworkSessionReply
    func check(_ settings: SettingsSnapshot, worker: WorkerClient, withService: Bool) async throws -> String
    func start(_ idleToken: UUID, settings: SettingsSnapshot, worker: WorkerClient, interactive: Bool,
               authorize: @escaping @Sendable () async throws -> Void) async throws -> NetworkSessionReply
    func stop(_ id: UUID, revision: UInt64) throws -> NetworkSessionReply
    func control(_ request: SessionControlRequest) async throws -> SessionControlReply
    func prepare(_ action: ServiceInstallationAction) throws
}

actor LiveHostSession: HostSession {
    private let bundle: Bundle
    private let location: WorkerLocation
    private let registration: WarpRegistration
    private let chainKey = ChainProfileKey()
    private let cloudKey = ChainProfileKey(storage: KeychainSecretStorage.cloudKey())
    private var identity: CodeIdentity?
    init(bundle: Bundle, location: WorkerLocation, registration: WarpRegistration) {
        self.bundle = bundle; self.location = location; self.registration = registration
    }

    func health() throws -> DesktopServiceState {
        identity = nil
        guard let fresh = try InstalledServiceStatus.identity() else { return .missing }
        _ = try ServiceClient.handshake(identity: fresh)
        identity = fresh
        return .ready
    }

    private func authenticated() throws -> CodeIdentity {
        guard let identity else { throw ServiceClientError.unavailable }
        return identity
    }

    func status(_ id: UUID?) throws -> NetworkSessionReply {
        try ServiceClient.sessionStatus(renewing: id, identity: authenticated())
    }

    func start(_ idleToken: UUID, settings: SettingsSnapshot, worker: WorkerClient, interactive: Bool,
               authorize: @escaping @Sendable () async throws -> Void) async throws -> NetworkSessionReply {
        let identity = try authenticated()
        try confirmUpdate()
        try await CampusIPv6.check(developerMode: settings.settings.devMode)
        let prepared = try await configuration(settings, worker: worker, interactive: interactive)
        let request = try transfer(prepared, identity: identity)
        try await validateRevisions(settings, prepared: prepared, worker: worker, interactive: interactive)
        try await authorize()
        return try ServiceClient.startSession(request, idleToken: idleToken, identity: identity)
    }

    func check(_ settings: SettingsSnapshot, worker: WorkerClient, withService: Bool) async throws -> String {
        let prepared = try await configuration(settings, worker: worker, interactive: true)
        if withService {
            let identity = try authenticated()
            let query = try transfer(prepared, identity: identity)
            _ = try ServiceClient.checkConfiguration(query, identity: identity)
        }
        try await validateRevisions(settings, prepared: prepared, worker: worker, interactive: true)
        let detail = ConfigurationSummary(prepared)
        return (withService ? "已通过服务核心检查" : "已通过本机配置检查（服务未安装）")
            + " · \(detail.proxyCount) 个节点，\(detail.ruleCount) 条规则"
    }

    private func configuration(_ settings: SettingsSnapshot, worker: WorkerClient, interactive: Bool) async throws -> PreparedConfiguration {
        let core = try await worker.runtimeStatus(), geo = try await worker.geodataStatus()
        guard core.available, geo.available else {
            throw HostFailure("prepare", "请在设置中准备网络核心与规则数据。")
        }
        let prepared: PreparedConfiguration
        if settings.cloud?.enabled == true {
            guard try await worker.maintainerNotice(refresh: false).cloudAllowed else {
                throw HostFailure("prepare", "备用配置当前不可用，请刷新公告或停用备用配置。")
            }
            let key = try await cloudKey.load(allowCreation: false, interactionAllowed: interactive)
            prepared = try await worker.prepareCloud(settings: settings, key: key, runtimeId: core.resourceId, geodataId: geo.resourceId)
        } else {
            let account = try await registration.ensureRegistered(interactionAllowed: interactive)
            let chainKey = settings.chain?.enabled == true ? try await self.chainKey.load(allowCreation: false, interactionAllowed: interactive) : nil
            prepared = try await registration.withSavedTunnel(revision: account.revision, interactionAllowed: interactive) { tunnel in
                try await worker.prepareConfiguration(settings: settings, credentialRevision: account.revision,
                    tunnel: tunnel, runtimeId: core.resourceId, geodataId: geo.resourceId, chainKey: chainKey)
            }
        }
        return prepared
    }

    private func transfer(_ prepared: PreparedConfiguration, identity: CodeIdentity) throws -> ConfigurationCheckRequest {
        try ServiceResourceTransfer.prepare(cache: location.cache, runtimeID: prepared.runtimeId,
                                           geodataID: prepared.geodataId, identity: identity)
        return ConfigurationCheckRequest(runtimeID: prepared.runtimeId, geodataID: prepared.geodataId,
            settingsRevision: prepared.settingsRevision, credentialRevision: prepared.credentialRevision,
            configuration: prepared.configuration)
    }

    private func validateRevisions(_ settings: SettingsSnapshot, prepared: PreparedConfiguration, worker: WorkerClient,
                                   interactive: Bool) async throws {
        guard try await worker.settings().revision == settings.revision else { throw WorkerClientError.staleConfiguration }
        if settings.cloud?.enabled == true {
            guard try await worker.maintainerNotice(refresh: false).cloudAllowed else { throw WorkerClientError.staleConfiguration }
        } else {
            guard try await registration.inspect(interactionAllowed: interactive)?.revision == prepared.credentialRevision else { throw CredentialError.conflict }
        }
    }

    private func confirmUpdate() throws {
        let store = UpdateTransactionStore(root: location.data)
        guard let pending = try store.load() else { return }
        guard let buildText = bundle.infoDictionary?["CFBundleVersion"] as? String, let build = UInt64(buildText) else {
            throw HostFailure("prepare", "升级身份尚未确认。")
        }
        if build < pending.release.build { return }
        try pending.verifyInstalledPayload(contents: bundle.bundleURL.appendingPathComponent("Contents"), build: build)
        try pending.verifyService(at: URL(fileURLWithPath: ServicePaths.executable))
        try store.clear(targetBuild: pending.release.build)
    }

    func stop(_ id: UUID, revision: UInt64) throws -> NetworkSessionReply {
        try ServiceClient.stopSession(sessionID: id, revision: revision, identity: authenticated())
    }
    func control(_ request: SessionControlRequest) async throws -> SessionControlReply {
        let identity = try authenticated()
        // A long node delay lookup must not monopolize the session actor and
        // prevent a heartbeat from renewing the service lease.
        return try await Task.detached {
            try ServiceClient.control(request, identity: identity, timeout: request.action == .traffic ? 2 : 30)
        }.value
    }
    func prepare(_ action: ServiceInstallationAction) throws {
        let app = bundle.bundleURL
        let signature = try CodeIdentity.protectedFile(at: app, identifier: "dev.freev6.desktop")
        try ServiceInstallationRequest(action: action, app: app, uid: getuid(), clientHash: signature.cdHash).execute()
    }
}
