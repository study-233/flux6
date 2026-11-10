import Foundation
import FreeV6Configuration

public actor WorkerClient {
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
        let progress: (@Sendable (WorkerProgress) -> Void)?
        var lastSequence: UInt64 = 0
    }
    private struct Empty: Encodable {}
    private struct Initialization: Encodable { let protocolVersion = 1 }
    private struct Patch: Encodable { let expectedRevision: UInt64; let changes: ProxyPreferences }
    private struct Cancellation: Encodable { let id: String }
    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: String?
        let method: String
        let params: Params
    }
    private struct Reply<Value: Decodable>: Decodable { let result: Value }
    private struct ProgressReply: Decodable { let params: WorkerProgress }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    private let location: WorkerLocation
    private var generation = UUID()
    private var transport: WorkerTransport?
    private var initialization: Task<WorkerHandshake, Error>?
    private var initializationID: UUID?
    private var retiring: WorkerTransport?
    private var reader: Task<Void, Never>?
    private var pending: [String: Pending] = [:]

    public init(location: WorkerLocation) { self.location = location }

    @discardableResult public func connect() async throws -> WorkerHandshake {
        if let initialization { return try await initialization.value }
        let attempt = UUID()
        let task = Task { try await establish() }
        initializationID = attempt
        initialization = task
        do { return try await task.value }
        catch {
            if initializationID == attempt { initialization = nil; initializationID = nil }
            throw error
        }
    }

    private func establish() async throws -> WorkerHandshake {
        try Task.checkCancellation()
        if let previous = retiring {
            await previous.waitForExit()
            if retiring === previous { retiring = nil }
        }
        try Task.checkCancellation()
        let transport = try WorkerTransport(location: location)
        self.transport = transport
        let session = UUID()
        generation = session
        reader = Task {
            do {
                for try await data in transport.messages { try receive(data, session: session) }
                disconnect(WorkerClientError.disconnected, session: session)
            } catch { disconnect(error, session: session) }
        }
        do {
            let handshake: WorkerHandshake = try await request("initialize", params: Initialization())
            guard handshake.protocolVersion == 1, handshake.platform == "darwin", handshake.architecture == Self.architecture,
                  handshake.maxFrameBytes == WorkerFrameDecoder.maximum, handshake.maxInFlight == 8,
                  handshake.capabilities.contains("settings.get"), handshake.capabilities.contains("settings.patch") else {
                throw WorkerClientError.incompatible
            }
            return handshake
        } catch { disconnect(error, session: session); throw error }
    }

    public func settings() async throws -> SettingsSnapshot {
        try await connect()
        let snapshot: SettingsSnapshot = try await request("settings.get", params: Empty())
        return try validate(snapshot)
    }

    public func save(_ preferences: ProxyPreferences, revision: UInt64) async throws -> SettingsSnapshot {
        try await connect()
        let snapshot: SettingsSnapshot = try await request("settings.patch", params: Patch(expectedRevision: revision, changes: preferences))
        return try validate(snapshot)
    }

    public func maintainerNotice(refresh: Bool) async throws -> MaintainerNotice {
        let method = refresh ? "notice.refresh" : "notice.status"
        guard try await connect().capabilities.contains(method) else { throw WorkerClientError.incompatible }
        let snapshot: MaintainerNotice = try await request(method, params: Empty(), timeout: 35_000_000_000)
        return try snapshot.validated()
    }

    public func trafficReport() async throws -> TrafficReport {
        guard try await connect().capabilities.contains("traffic.get") else { throw WorkerClientError.incompatible }
        return try await request("traffic.get", params: Empty())
    }

    public func observeTraffic(sessionID: UUID, upload: UInt64, download: UInt64) async throws -> TrafficReport {
        struct Observation: Encodable { let sessionID: UUID; let upload: UInt64; let download: UInt64 }
        guard try await connect().capabilities.contains("traffic.observe") else { throw WorkerClientError.incompatible }
        return try await request("traffic.observe", params: Observation(sessionID: sessionID, upload: upload, download: download))
    }

    public func runtimeStatus() async throws -> RuntimePackageInfo {
        try await connect()
        let result: RuntimePackageInfo = try await request("runtime.status", params: Empty(), timeout: 35_000_000_000)
        return try validateRuntime(result)
    }

    public func downloadRuntime(progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> RuntimePackageInfo {
        try await connect()
        let result: RuntimePackageInfo = try await request("runtime.download", params: Empty(), timeout: 190_000_000_000, progress: progress)
        return try validateRuntime(result)
    }

    public func registerWarp(name: String, progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WarpCredential {
        struct Registration: Encodable { let name: String }
        let handshake = try await connect()
        guard handshake.capabilities.contains("warp.register") else { throw WorkerClientError.incompatible }
        let result: WarpCredential = try await request("warp.register", params: Registration(name: name),
                                                       timeout: 50_000_000_000, progress: progress)
        return try result.validated()
    }

    public func geodataStatus() async throws -> GeodataPackageInfo {
        let handshake = try await connect()
        guard handshake.capabilities.contains("geodata.status") else { throw WorkerClientError.incompatible }
        let result: GeodataPackageInfo = try await request("geodata.status", params: Empty(), timeout: 35_000_000_000)
        return try result.validated()
    }

    public func prepareConfiguration(settings: SettingsSnapshot, credentialRevision: UUID, tunnel: TunnelCredential,
                                     runtimeId: String, geodataId: String, chainKey: Data? = nil) async throws -> PreparedConfiguration {
        struct Input: Encodable {
            let source = "warp"
            let settingsRevision: UInt64
            let credentialRevision: UUID
            let tunnel: TunnelCredential
            let chainKey: Data?
        }
        let handshake = try await connect()
        guard handshake.capabilities.contains("configuration.prepare") else { throw WorkerClientError.incompatible }
        let tunnel = try tunnel.validated()
        let result: PreparedConfiguration = try await request("configuration.prepare",
            params: Input(settingsRevision: settings.revision, credentialRevision: credentialRevision, tunnel: tunnel, chainKey: chainKey), timeout: 35_000_000_000)
        return try result.validated(settings: settings, revision: credentialRevision, tunnel: tunnel, runtimeId: runtimeId, geodataId: geodataId)
    }

    public func prepareGeodata(progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> GeodataPackageInfo {
        let handshake = try await connect()
        guard handshake.capabilities.contains("geodata.prepare") else { throw WorkerClientError.incompatible }
        let result: GeodataPackageInfo = try await request("geodata.prepare", params: Empty(), timeout: 190_000_000_000, progress: progress)
        return try result.validated()
    }

    private func validateRuntime(_ result: RuntimePackageInfo) throws -> RuntimePackageInfo {
        guard result.platform == "darwin", result.architecture == Self.architecture,
              result.sha256.count == 64, result.binarySha256.count == 64,
              !result.resourceId.isEmpty, result.resourceId.count <= 128 else { throw WorkerClientError.invalidResponse }
        return result
    }

    public func shutdown() async {
        disconnect(WorkerClientError.disconnected, session: generation)
        if let previous = retiring { await previous.waitForExit() }
    }

    private func validate(_ snapshot: SettingsSnapshot) throws -> SettingsSnapshot {
        if let cloud = snapshot.cloud {
            guard (1...ImportedCloudNodes.limit).contains(cloud.names.count), Set(cloud.names).count == cloud.names.count,
                  cloud.names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                  ISO8601DateFormatter().date(from: cloud.updatedAt) != nil,
                  cloud.ignored.count <= 64, cloud.ignored.allSatisfy({ $0.utf8.count <= 64 }),
                  !(cloud.enabled && snapshot.chain?.enabled == true) else { throw WorkerClientError.invalidResponse }
        }
        if let chain = snapshot.chain {
            guard (1...64).contains(chain.names.count), Set(chain.names).count == chain.names.count,
                  chain.names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw WorkerClientError.invalidResponse
            }
        }
        guard snapshot.schemaVersion == 1, snapshot.settings.campusCidrs.count <= 2048, snapshot.settings.blacklist.count <= 2048 else {
            throw WorkerClientError.incompatible
        }
        return snapshot
    }

    private func request<Params: Encodable, Value: Decodable>(_ method: String, params: Params, timeout: UInt64 = 10_000_000_000,
                                                            progress: (@Sendable (WorkerProgress) -> Void)? = nil) async throws -> Value {
        let id = UUID().uuidString
        let session = generation
        let frame = try WorkerFrameDecoder.encode(JSONEncoder().encode(Request(id: id, method: method, params: params)))
        let data: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard let transport else { continuation.resume(throwing: WorkerClientError.disconnected); return }
                guard pending.count < 8 else { continuation.resume(throwing: WorkerClientError.busy); return }
                let timer = Task {
                    do { try await Task.sleep(nanoseconds: timeout) }
                    catch { return }
                    if pending[id] != nil { disconnect(WorkerClientError.timeout, session: session) }
                }
                pending[id] = Pending(continuation: continuation, timeout: timer, progress: progress)
                transport.send(frame) { failure in
                    if let failure { Task { await self.disconnect(failure, session: session) } }
                }
            }
        } onCancel: { Task { await self.cancel(id, session: session) } }
        do { return try JSONDecoder().decode(Reply<Value>.self, from: data).result }
        catch let failure as ChainImportValidationError { throw failure }
        catch { disconnect(WorkerClientError.invalidResponse, session: session); throw WorkerClientError.invalidResponse }
    }

    private func receive(_ data: Data, session: UUID) throws {
        guard generation == session else { return }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["jsonrpc"] as? String == "2.0" else { throw WorkerClientError.invalidResponse }
        if let method = response["method"] as? String, response["id"] == nil {
            guard method == "$/progress" else { return }
            let update = try JSONDecoder().decode(ProgressReply.self, from: data).params
            guard update.received >= 0, update.total >= -1, update.attempt >= 0, update.attempts >= update.attempt,
                  update.attempts <= 16, ["checking", "copying", "downloading", "verifying", "registering", "enrolling", "rendering"].contains(update.phase),
                  update.asset == nil || ["GeoSite.dat", "geoip.dat", "country.mmdb"].contains(update.asset!) else {
                throw WorkerClientError.invalidResponse
            }
            guard var item = pending[update.requestId], update.sequence > item.lastSequence else { return }
            item.lastSequence = update.sequence
            pending[update.requestId] = item
            item.progress?(update)
            return
        }
        guard let id = response["id"] as? String,
              (response["error"] == nil) != (response["result"] == nil) else { throw WorkerClientError.invalidResponse }
        guard let item = pending.removeValue(forKey: id) else { return } // canceled request's late reply
        item.timeout.cancel()
        if let failure = response["error"] {
            do {
                let encoded = try JSONSerialization.data(withJSONObject: failure)
                item.continuation.resume(throwing: try JSONDecoder().decode(WorkerRemoteError.self, from: encoded))
            } catch { item.continuation.resume(throwing: WorkerClientError.invalidResponse); throw error }
        } else { item.continuation.resume(returning: data) }
    }

    private func cancel(_ id: String, session: UUID) {
        guard generation == session, let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel()
        item.continuation.resume(throwing: CancellationError())
        if let frame = try? WorkerFrameDecoder.encode(JSONEncoder().encode(Request(id: Optional<String>.none, method: "$/cancelRequest", params: Cancellation(id: id)))) {
            transport?.send(frame) { failure in
                if let failure { Task { await self.disconnect(failure, session: session) } }
            }
        }
    }

    private func disconnect(_ failure: Error, session: UUID) {
        guard generation == session else { return }
        generation = UUID()
        if let transport { retiring = transport; transport.close() }
        transport = nil
        reader?.cancel(); reader = nil
        initialization?.cancel(); initialization = nil
        initializationID = nil
        let items = pending.values
        pending.removeAll()
        for item in items { item.timeout.cancel(); item.continuation.resume(throwing: failure) }
    }
}


public enum ChainImportSource: Sendable { case file(URL), subscription(String), refresh }

extension WorkerClient {
    private struct ChainInput: Encodable {
        let expectedRevision: UInt64
        let key: Data
        var file: String?
        var url: String?
        var refresh: Bool?
    }
    private struct ChainPreview: Decodable { let token: String; let nodes: ImportedChainNodes }
    private struct ChainMutation: Encodable {
        let expectedRevision: UInt64
        var token: String?
        var enabled: Bool?
    }

    public func importChain(from source: ChainImportSource, settings: SettingsSnapshot, key: Data) async throws -> SettingsSnapshot {
        let capabilities = try await connect().capabilities
        guard capabilities.contains("chain.preview"), capabilities.contains("chain.commit") else { throw WorkerClientError.incompatible }
        var input = ChainInput(expectedRevision: settings.revision, key: key)
        let origin: ChainSummary.Source
        switch source {
        case .file(let url):
            guard url.isFileURL else { throw WorkerClientError.invalidResponse }
            input.file = url.path; origin = .file
        case .subscription(let url): input.url = url; origin = .url
        case .refresh: input.refresh = true; origin = .url
        }
        let preview: ChainPreview = try await request("chain.preview", params: input, timeout: 35_000_000_000)
        try Task.checkCancellation()
        guard preview.token.utf8.count == 32, preview.token.allSatisfy(\.isHexDigit) else { throw WorkerClientError.invalidResponse }
        let saved: SettingsSnapshot = try await request("chain.commit", params: ChainMutation(expectedRevision: settings.revision, token: preview.token))
        guard saved.revision > settings.revision, saved.chain?.source == origin, saved.chain?.enabled == true,
              saved.chain?.names == preview.nodes.names else { throw WorkerClientError.invalidResponse }
        return try validate(saved)
    }

    public func setChainEnabled(_ enabled: Bool, settings: SettingsSnapshot) async throws -> SettingsSnapshot {
        guard try await connect().capabilities.contains("chain.enable") else { throw WorkerClientError.incompatible }
        let saved: SettingsSnapshot = try await request("chain.enable", params: ChainMutation(expectedRevision: settings.revision, enabled: enabled))
        guard saved.revision > settings.revision, saved.chain?.enabled == enabled,
              saved.chain?.names == settings.chain?.names else { throw WorkerClientError.invalidResponse }
        return try validate(saved)
    }

    public func clearChain(settings: SettingsSnapshot) async throws -> SettingsSnapshot {
        guard try await connect().capabilities.contains("chain.clear") else { throw WorkerClientError.incompatible }
        let saved: SettingsSnapshot = try await request("chain.clear", params: ChainMutation(expectedRevision: settings.revision))
        guard saved.revision > settings.revision, saved.chain == nil else { throw WorkerClientError.invalidResponse }
        return try validate(saved)
    }
}

public enum CloudImportSource: Sendable { case portal(String), url(String), file(URL), refresh }
public enum CloudMutation: Sendable { case enable(Bool), clear, portal(String) }

extension WorkerClient {
    private struct CloudInput: Encodable {
        let expectedRevision: UInt64
        let key: Data
        let source: String
        let value: String?
    }
    private struct CloudPreview: Decodable { let token: String; let nodes: ImportedCloudNodes }

    public func importCloud(from source: CloudImportSource, settings: SettingsSnapshot, key: Data) async throws -> SettingsSnapshot {
        let capabilities = try await connect().capabilities
        guard capabilities.contains("cloud.preview"), capabilities.contains("cloud.commit") else { throw WorkerClientError.incompatible }
        let kind: String, value: String?
        let expectedSource: CloudSummary.Source?
        switch source {
        case .portal(let host): kind = "portal"; value = host; expectedSource = .portal
        case .url(let url): kind = "url"; value = url; expectedSource = .url
        case .file(let file):
            guard file.isFileURL else { throw WorkerClientError.invalidResponse }
            kind = "file"; value = file.path; expectedSource = .file
        case .refresh: kind = "refresh"; value = nil; expectedSource = settings.cloud?.source
        }
        let input = CloudInput(expectedRevision: settings.revision, key: key, source: kind, value: value)
        let preview: CloudPreview = try await request("cloud.preview", params: input, timeout: 35_000_000_000)
        try Task.checkCancellation()
        guard preview.token.utf8.count == 32, preview.token.allSatisfy(\.isHexDigit) else { throw WorkerClientError.invalidResponse }
        let saved: SettingsSnapshot = try await request("cloud.commit", params: ChainMutation(expectedRevision: settings.revision, token: preview.token))
        guard let profile = saved.cloud, profile.enabled, profile.names == preview.nodes.names, profile.source == expectedSource,
              saved.chain == settings.chain, saved.settings == settings.settings, saved.revision > settings.revision else { throw WorkerClientError.invalidResponse }
        return try validate(saved)
    }

    public func changeCloud(_ change: CloudMutation, settings: SettingsSnapshot) async throws -> SettingsSnapshot {
        struct Params: Encodable { let expectedRevision: UInt64; var enabled: Bool?; var portalHost: String? }
        var input = Params(expectedRevision: settings.revision)
        let method: String
        switch change {
        case .enable(let enabled): method = "cloud.enable"; input.enabled = enabled
        case .portal(let host): method = "cloud.portal"; input.portalHost = host
        case .clear: method = "cloud.clear"
        }
        guard try await connect().capabilities.contains(method) else { throw WorkerClientError.incompatible }
        let saved: SettingsSnapshot = try await request(method, params: input)
        guard saved.revision > settings.revision, saved.settings == settings.settings, saved.chain == settings.chain else { throw WorkerClientError.invalidResponse }
        switch change {
        case .enable(let flag):
            guard saved.cloud?.enabled == flag, saved.cloud?.id == settings.cloud?.id else { throw WorkerClientError.invalidResponse }
        case .clear: guard saved.cloud == nil else { throw WorkerClientError.invalidResponse }
        case .portal: guard saved.cloud == settings.cloud else { throw WorkerClientError.invalidResponse }
        }
        return try validate(saved)
    }

    public func prepareCloud(settings: SettingsSnapshot, key: Data, runtimeId: String, geodataId: String) async throws -> PreparedConfiguration {
        struct Input: Encodable { let source = "cloud"; let settingsRevision: UInt64; let credentialRevision: UUID; let profileKey: Data }
        guard let cloud = settings.cloud, cloud.enabled, settings.chain?.enabled != true,
              try await connect().capabilities.contains("cloud.commit") else { throw WorkerClientError.incompatible }
        let result: PreparedConfiguration = try await request("configuration.prepare",
            params: Input(settingsRevision: settings.revision, credentialRevision: cloud.id, profileKey: key), timeout: 35_000_000_000)
        guard result.schemaVersion == 1, result.settingsRevision == settings.revision, result.credentialRevision == cloud.id,
              result.runtimeId == runtimeId, result.geodataId == geodataId else { throw WorkerClientError.invalidResponse }
        try result.configuration.requireCloud(names: cloud.names, mode: settings.settings.mode.rawValue)
        return result
    }
}
