import Foundation

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
                  update.attempts <= 16, ["checking", "copying", "downloading", "verifying", "registering", "enrolling"].contains(update.phase),
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
