import Combine
import CryptoKit
import Darwin
import Foundation
import FreeV6Business
import FreeV6Desktop
import FreeV6System

/// One host per application, shared by the main window, settings and native
/// menus. Views own subscriptions, never a worker, session, or heartbeat.
@MainActor public final class FreeV6HostCoordinator {
    let worker: WorkerClient
    let network = DesktopNetworkSession()
    let controls: DesktopCoreControls
    let logs: DesktopLogs
    let settings: HostSettings
    let backend: any HostSession
    let isolated: Bool
    var service = DesktopServiceState.checking
    var error: String?
    var report: TrafficReport?
    var cursor = 0, sampleSeq = 0
    var started: Date?
    var configurationCheckMessage: String?
    var configurationCheckRevision: UInt64?
    var checkingConfiguration = false
    var setupTask: Task<Void, Never>?
    var setupStep = 0
    var setupStatus = "安装网络服务后，将自动准备连接所需的资源和账户。"
    var setupError: String?
    var downloadTask: Task<Void, Never>?
    var downloadQuery: SessionControlRequest?
    var downloadStarted: Date?
    var downloadResults: [String: [String: [String: Any]]] = [:]
    var downloadTarget: SessionControlTarget?
    var downloadTotal = 0, downloadCompleted = 0
    var downloadCancelling = false
    private var awaitingRestoration: SessionControlTarget?
    private var observers: [UUID: ([String: Any]) -> Void] = [:]
    private var ready: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var launchAttempt: Task<Void, Never>?
    private var automaticRequest: (id: String, attempt: UUID)?
    private var closing = false
    private var commandActive = false
    private var lifecycleActive = false
    private var sampling = false
    private var subscriptions = Set<AnyCancellable>()
    private struct Outcome { let code: String?; let message: String? }
    private struct Request {
        let signature: Data
        let work: Task<Outcome, Never>
    }
    private var tasks: [String: Request] = [:]
    private var completed: [String: (Data, Outcome)] = [:], order: [String] = []
    private var tail: Task<Outcome, Never>?

    #if !FREEV6_RELEASE_HOST
    public static func preview(bundle: Bundle = .main) throws -> FreeV6HostCoordinator {
        let base = "dev.freev6.flutter-host"
        let identifier = bundle.bundleIdentifier ?? ""
        let qaPrefix = base + ".qa."
        let directory: String
        if identifier == base { directory = base + "-integration" }
        else if identifier.hasPrefix(qaPrefix),
                let id = UUID(uuidString: String(identifier.dropFirst(qaPrefix.count))),
                identifier.dropFirst(qaPrefix.count).lowercased() == id.uuidString.lowercased() {
            // Each automated UI run has its own defaults domain and worker
            // lease. It cannot modify the interactive acceptance app's data.
            directory = qaPrefix + id.uuidString.lowercased()
        } else { throw HostFailure("invalidHost", "隔离宿主的应用身份不匹配。") }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        guard let confirmed = realpath(support.path, nil) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { free(confirmed) }
        let root = URL(fileURLWithPath: String(cString: confirmed), isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0 else {
            throw HostFailure("storage", "独立宿主目录必须是当前用户专用的文件夹。")
        }
        let content = bundle.bundleURL.appendingPathComponent("Contents")
        let location = WorkerLocation(executable: content.appendingPathComponent("Helpers/freev6-worker"),
            data: root.appendingPathComponent("data"), resources: content.appendingPathComponent("Resources"),
            cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        return FreeV6HostCoordinator(location: location, defaults: .standard,
            backend: IsolatedHostSession(executable: content.appendingPathComponent("Helpers/freev6-session-fixture")), isolated: true,
            notices: content.appendingPathComponent("Resources/Notices"))
    }

    #endif

    public static func live(bundle: Bundle = .main) throws -> FreeV6HostCoordinator {
        guard bundle.bundleIdentifier == "dev.freev6.desktop" else {
            throw HostFailure("invalidHost", "正式宿主的应用身份不匹配。")
        }
        let location = try WorkerLocation.application(bundle: bundle)
        let worker = WorkerClient(location: location)
        let registration = WarpRegistration(vault: WarpCredentialVault()) { name, progress in
            try await worker.registerWarp(name: name, progress: progress)
        }
        return FreeV6HostCoordinator(location: location, defaults: .standard,
            backend: LiveHostSession(bundle: bundle, location: location, registration: registration), isolated: false,
            notices: bundle.resourceURL?.appendingPathComponent("Notices"), worker: worker, registration: registration)
    }

    init(location: WorkerLocation, defaults: UserDefaults, backend: any HostSession, isolated: Bool, notices: URL?,
         worker: WorkerClient? = nil, registration: WarpRegistration? = nil) {
        self.backend = backend
        self.isolated = isolated
        self.worker = worker ?? WorkerClient(location: location)
        controls = DesktopCoreControls(defaults: defaults)
        logs = DesktopLogs(directory: location.logs)
        settings = HostSettings(worker: self.worker, defaults: defaults, logs: logs, preview: isolated,
                                noticesDirectory: notices, registration: registration)
        settings.onChange = { [weak self] in self?.publish("state") }
        settings.onLogChange = { [weak self] in self?.publish("logs") }
        logs.record(.opened)
        network.$phase.removeDuplicates().dropFirst().sink { [weak self] phase in
            guard let self else { return }
            if phase != .running { self.controls.bind(nil) }
            let event: DesktopEvent
            switch phase {
            case .idle: event = .idle
            case .running: event = .connected
            case .connecting: event = .connecting
            case .disconnecting: event = .disconnecting
            case .occupied: event = .occupied
            case .recovering: event = .recovery
            case .unknown: event = .unknown
            }
            self.logs.record(event)
            Task { @MainActor [weak self] in self?.publish("state") }
        }.store(in: &subscriptions)
        controls.$measuringMember.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish("state") }
        }.store(in: &subscriptions)
    }

    deinit { clock?.cancel(); ready?.cancel(); launchAttempt?.cancel() }

    private func bootstrap() async {
        if ready == nil {
            ready = Task { [weak self] in
                guard let self else { return }
                await self.settings.load()
                await self.refresh(health: true)
                // Adopt a working installation without forcing existing users
                // through onboarding. This lookup never summons Keychain UI.
                if self.settings.accepted && self.service == .ready && self.settings.coreReady && self.settings.geodataReady {
                    await self.settings.refreshAccountSilently()
                    if self.settings.account != nil || self.settings.stored?.cloud?.enabled == true || self.network.phase == .running {
                        self.settings.setupCompleted = true
                    }
                }
                self.launchAttempt = Task { [weak self] in await self?.startAutomatically() }
                self.clock = Task { [weak self] in
                    var ticks = 0
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        guard let self, !self.closing else { return }
                        ticks += 1
                        if ticks % 2 == 0 { await self.refresh(health: false) }
                        await self.takeSample()
                    }
                }
            }
        }
        await ready?.value
    }

    private func startAutomatically() async {
        let startup = settings.startup
        await startup.runAutomatic(prerequisite: {
            guard !closing, !lifecycleActive, service == .ready, network.phase == .idle,
                  !settings.blockedForConnection, settings.stored != nil else { return "当前状态不支持自动连接。" }
            return nil
        }, waitForNetwork: { [isolated] in
            if isolated { return true }
            return await startup.waitForNetwork()
        }, inspect: {}, connect: { attempt in
            let id = UUID().uuidString
            automaticRequest = (id, attempt)
            defer { automaticRequest = nil }
            let state = makeSnapshot()
            let reply = await command(["version": 1, "name": "connect", "id": id,
                                       "revision": state["revision"] ?? NSNull(), "sessionId": NSNull(), "arguments": [:]])
            return reply["error"] as? String
        })
        publish("state")
    }

    func expectedAutomaticAttempt(_ id: String?) -> UUID? {
        guard let auto = automaticRequest, auto.id == id else { return nil }
        return auto.attempt
    }

    public func snapshot() async -> [String: Any] {
        await bootstrap()
        return makeSnapshot()
    }

    @discardableResult public func observe(_ receive: @escaping ([String: Any]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = receive
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    func publish(_ kind: String) {
        guard !closing else { return }
        cursor += 1
        guard !observers.isEmpty else { return }
        let payload: [String: Any] = ["version": 1, "cursor": cursor, "kind": kind,
            "snapshot": kind == "traffic" ? trafficSnapshot() : makeSnapshot()]
        for send in Array(observers.values) { send(payload) }
    }

    // Deduplicate even while an earlier invocation is suspended. Keep one
    // serial mutation queue for all surfaces; validate expectations at execution
    // time, not when a request enters the queue.
    public func command(_ envelope: [String: Any]) async -> [String: Any] {
        await bootstrap()
        func reply(_ outcome: Outcome) -> [String: Any] {
            var result: [String: Any] = ["ok": outcome.code == nil, "snapshot": makeSnapshot()]
            if let code = outcome.code { result["code"] = code; result["error"] = outcome.message }
            return result
        }
        guard !closing, envelope["version"] as? Int == 1, let id = envelope["id"] as? String,
              !id.isEmpty, id.utf8.count <= 128, let name = envelope["name"] as? String,
              let encoded = try? JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys) else {
            return reply(Outcome(code: "invalid", message: "命令格式或协议版本无效。"))
        }
        if name == "logs.page" || name == "logs.export" {
            guard settings.accepted else { return reply(Outcome(code: "notAccepted", message: "请先阅读并同意协议。")) }
            let args = envelope["arguments"] as? [String: Any] ?? [:]
            do {
                let data = try name == "logs.page" ? settings.logPages.read(args) : settings.logPages.export(args)
                return ["ok": true, "data": data]
            } catch { return reply(Outcome(code: "logView", message: error.localizedDescription)) }
        }
        if ["connect", "disconnect", "retryRecovery", "setMode", "setNode", "prepareService"].contains(name),
           expectedAutomaticAttempt(id) == nil { settings.startup.cancelAutomatic() }
        let hash = Data(SHA256.hash(data: encoded))
        let collision = Outcome(code: "duplicateID", message: "命令标识已用于不同操作。")
        if let prior = completed[id] { return reply(prior.0 == hash ? prior.1 : collision) }
        if let existing = tasks[id] {
            guard existing.signature == hash else { return reply(collision) }
            return reply(await existing.work.value)
        }
        guard tasks.count < 64 else { return reply(Outcome(code: "busy", message: "正在处理其他操作。")) }
        let previous = tail
        let work = Task { @MainActor () -> Outcome in
            _ = await previous?.value
            guard !self.closing, !self.lifecycleActive else { return Outcome(code: "closed", message: "正在退出或准备更新。") }
            self.commandActive = true
            defer { self.commandActive = false }
            do {
                try await self.perform(name, envelope: envelope)
                self.error = nil
                self.publish("state")
                return Outcome(code: nil, message: nil)
            } catch {
                self.error = error.localizedDescription
                self.publish("state")
                return Outcome(code: (error as? HostFailure)?.code ?? "operationFailed", message: error.localizedDescription)
            }
        }
        tasks[id] = Request(signature: hash, work: work); tail = work
        let result = await work.value
        tasks[id] = nil
        completed[id] = (hash, result); order.append(id)
        if order.count > 128 { completed[order.removeFirst()] = nil }
        if tasks.isEmpty { tail = nil }
        return reply(result)
    }

    var modeSource: DashboardWorkingMode? {
        DashboardWorkingMode.source(phase: network.phase, service: service, mayOwnSession: network.mayOwnSession)
    }

    var canCheckConfiguration: Bool {
        settings.accepted && !settings.blockedForConnection && settings.stored != nil && !checkingConfiguration &&
            !network.mayOwnSession && (service == .missing || service == .ready && network.phase == .idle)
    }

    var groups: [DesktopNodeGroup] {
        guard settings.accepted else { return [] }
        if network.phase == .running { return controls.state?.groups.map(DesktopNodeGroup.init(session:)) ?? [] }
        guard modeSource == .savedDefault else { return [] }
        guard let stored = settings.stored else { return controls.previousGroups }
        if let cloud = stored.cloud, cloud.enabled { return [controls.offlineGroup(.access, names: cloud.names, source: .configuration)] }
        #if FREEV6_RELEASE_HOST
        let accessNames = DesktopNodeGroup.warpNames
        #else
        let accessNames = isolated ? IsolatedHostSession.nodes : DesktopNodeGroup.warpNames
        #endif
        var result = [controls.offlineGroup(.access, names: accessNames, source: .configuration)]
        if let chain = stored.chain, chain.enabled { result.append(controls.offlineGroup(.chain, names: chain.names, source: .configuration)) }
        return result
    }

    func refresh(health: Bool, force: Bool = false) async {
        guard !closing, !lifecycleActive else { return }
        let prior = network.runningTarget
        let oldPhase = network.phase, oldGroup = controls.state, priorError = network.statusError
        do {
            if health {
                do { service = try await backend.health() }
                catch {
                    service = .needsRepair; network.invalidate()
                    throw error
                }
                if service != .ready { network.invalidate() }
            }
            if service == .ready { await network.refresh { [backend] in try await backend.status($0) } }
            // A slow credential or download operation must not suspend the
            // lease heartbeat. Core inspection can wait until that write ends.
            if commandActive && !force { return }
            await inspectControls(restoring: prior != network.runningTarget)
            if health && settings.accepted { report = try await worker.trafficReport() }
        } catch {
            self.error = error.localizedDescription
        }
        if health || oldPhase != network.phase || oldGroup != controls.state || priorError != network.statusError {
            publish("state")
        }
    }

    func inspectControls(restoring: Bool) async {
        let target = network.runningTarget
        if restoring || target != controls.target { awaitingRestoration = target }
        controls.bind(target)
        guard let target else { started = nil; awaitingRestoration = nil; return }
        await controls.inspect { [backend] in try await backend.control($0) }
        // A transient first inspect must not consume the offline preference.
        guard awaitingRestoration == target, target == network.runningTarget, controls.state != nil else { return }
        awaitingRestoration = nil
        for group in SessionNodeGroup.allCases {
            if let request = controls.restoration(for: group) {
                _ = await controls.change(request) { [backend] in try await backend.control($0) }
            }
        }
    }

    private func takeSample() async {
        guard !sampling, !commandActive, let target = network.runningTarget else { return }
        sampling = true
        defer { sampling = false }
        if let sample = await controls.sample(using: { [backend] in try await backend.control($0) }), target == network.runningTarget {
            do {
                let value = try await worker.observeTraffic(sessionID: target.sessionID, upload: sample.upTotal, download: sample.downTotal)
                if target == network.runningTarget { report = value }
            } catch { self.error = error.localizedDescription }
        }
        sampleSeq += 1; publish("traffic")
    }

    func stop(_ id: UUID, _ revision: UInt64) async throws -> NetworkSessionReply {
        let request = SessionControlRequest(.init(sessionID: id, revision: revision), .traffic)
        let sample = try? await backend.control(request).traffic
        let result = try await backend.stop(id, revision: revision)
        if let sample { report = try? await worker.observeTraffic(sessionID: id, upload: sample.upTotal, download: sample.downTotal) }
        started = nil
        return result
    }

    public func prepareForUpdate() async throws {
        settings.startup.cancelAutomatic()
        guard !commandActive, tasks.isEmpty, !lifecycleActive, !settings.blockedForConnection, !settings.pendingCredential else {
            throw HostFailure("busy", "请完成当前操作并保存编辑。")
        }
        lifecycleActive = true
        defer { lifecycleActive = false }
        await cancelDownload()
        try await settleNetwork(forUpdate: true)
    }

    private func settleNetwork(forUpdate: Bool) async throws {
        if service != .ready {
            // Refresh identity before relying on a stale "not installed" state.
            do { service = try await backend.health() }
            catch InstallationError.inconsistentInstallation where !forUpdate && !network.mayOwnSession {
                // An incomplete installation must not trap an idle/onboarding UI.
                // Known sessions still require recovery; updates still require a
                // healthy installation before replacing the shared application.
                return
            }
        }
        guard service == .ready else {
            if network.mayOwnSession { throw ServiceClientError.unavailable }
            return
        }
        let status: DesktopNetworkSession.Status = { [backend] in try await backend.status($0) }
        if forUpdate { try await network.disconnectBeforeUpdate(status: status, stop: stop) }
        else { try await network.disconnectBeforeExit(status: status, stop: stop) }
    }

    public func shutdown() async throws {
        await bootstrap()
        settings.startup.cancelAutomatic()
        guard !lifecycleActive, tasks.isEmpty, !settings.busy, !settings.pendingCredential else {
            throw HostFailure("busy", "请先完成当前操作并保存待处理凭据。")
        }
        lifecycleActive = true
        defer { lifecycleActive = false }
        await cancelDownload()
        try await settleNetwork(forUpdate: false)
        closing = true
        launchAttempt?.cancel(); launchAttempt = nil
        clock?.cancel(); clock = nil
        await logs.finishWrites()
        await worker.shutdown()
    }
}
