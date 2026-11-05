import Darwin
import Foundation

/// Owns the installation lease between XPC calls. Only the owning UID with the
/// matching session ID can renew the client heartbeat. A fresh idle token
/// prevents an old or replayed start from taking effect after a later stop.
public final class ServiceNetworkSessions: @unchecked Sendable {
    private let resources: ServiceResourceStore
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let restart: () -> Void
    private var retained: PreparedSessionStore?
    private var idleToken = UUID()
    private var controlToken = UUID()
    private let samples = DispatchSemaphore(value: 3)
    private var lastContact: TimeInterval = 0
    private var needsRecovery = true
    private var stopRequested = false
    private var restartRequired = false
    #if DEBUG
    private var isolated = false
    #endif

    public init(resources: ServiceResourceStore, restartAfterUncertainLaunch: @escaping () -> Void) {
        self.resources = resources
        restart = restartAfterUncertainLaunch
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.freev6.session-supervisor", qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 3)
        timer.setEventHandler { [weak self] in self?.maintain() }
        timer.resume()
    }
    deinit { timer.cancel() }

    #if DEBUG
    public func useIsolatedNetwork() throws {
        guard geteuid() != 0 else { throw SessionStoreError.wrongOwner }
        lock.lock(); defer { lock.unlock() }
        isolated = true
    }
    #endif

    private func store() throws -> PreparedSessionStore {
        if let retained { return retained }
        let value = try resources.sessionStore()
        #if DEBUG
        if isolated { try NetworkRunProbe.configure(value, data: value.data) }
        #endif
        return value
    }

    public func start(_ data: Data, uid: uid_t) throws -> NetworkSessionReply {
        guard uid != 0 else { throw SessionStoreError.wrongOwner }
        let start = try NetworkSessionStart.decode(data)
        guard lock.lock(before: Date(timeIntervalSinceNow: 0.5)) else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        guard retained == nil, idleToken == start.idleToken else { throw SessionStoreError.invalidTransition }
        let store = try store()
        try store.recoverInterruptedSession()
        needsRecovery = false
        idleToken = UUID()
        retained = store
        do {
            let prepared = try resources.prepareSession(JSONEncoder().encode(start.request), clientUID: uid, sessions: store)
            let active = try store.startRunning(sessionID: prepared.sessionID, clientUID: uid)
            lastContact = ProcessInfo.processInfo.systemUptime
            return NetworkSessionReply(start.request.requestID, phase: .running, record: active)
        } catch {
            stopRequested = true
            if let record = try? store.current() {
                if let stage = record.run?.stage, [.registering, .starting].contains(stage) { restartRequired = true }
            }
            // The timer retries uncertain recovery. Release a clean lease now.
            if (try? store.current() == nil) == true { release() }
            throw error
        }
    }

    public func status(_ data: Data, uid: uid_t) throws -> NetworkSessionReply {
        guard uid != 0 else { throw SessionStoreError.wrongOwner }
        let query = try NetworkSessionQuery.decode(data, stopping: false)
        guard lock.lock(before: Date(timeIntervalSinceNow: 0.5)) else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        let store = try store()
        guard let record = try store.current() else {
            if retained != nil { release() }
            return NetworkSessionReply(query.requestID, phase: .stopped, idleToken: idleToken)
        }
        guard record.clientUID == uid else { return NetworkSessionReply(query.requestID, phase: .occupied) }
        if record.run?.stage == .active, retained === store, !stopRequested {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastContact < 30, (try? store.coreIsPresent(record)) == true {
                if query.sessionID == record.sessionID { lastContact = now }
                return NetworkSessionReply(query.requestID, phase: .running, record: record)
            }
            stopRequested = true
        }
        return NetworkSessionReply(query.requestID, phase: .recoveryRequired, record: record.run == nil ? nil : record)
    }

    public func stop(_ data: Data, uid: uid_t) throws -> NetworkSessionReply {
        guard uid != 0 else { throw SessionStoreError.wrongOwner }
        let query = try NetworkSessionQuery.decode(data, stopping: true)
        guard let sessionID = query.sessionID, let revision = query.revision else { throw ServiceMessageError.invalid }
        guard lock.lock(before: Date(timeIntervalSinceNow: 0.5)) else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        let store = try store()
        if let record = try store.current() {
            guard record.clientUID == uid else { throw SessionStoreError.wrongOwner }
            guard record.sessionID == sessionID, record.run?.revision == revision else { throw SessionStoreError.invalidTransition }
            stopRequested = true
            retained = store
            try store.stopRunning(sessionID: sessionID, clientUID: uid, revision: revision)
            release()
        }
        return NetworkSessionReply(query.requestID, phase: .stopped, idleToken: idleToken)
    }

    private func withActiveController<T>(_ query: SessionControlRequest, uid: uid_t,
                                         _ perform: (CoreController) throws -> T) throws -> T {
        guard lock.lock(before: Date(timeIntervalSinceNow: 0.5)) else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        guard uid != 0, let retained, !stopRequested, ProcessInfo.processInfo.systemUptime - lastContact < 30 else {
            throw SessionStoreError.invalidTransition
        }
        return try perform(retained.activeController(target: query.target, uid: uid))
    }

    public func control(_ data: Data, uid: uid_t) throws -> SessionControlReply {
        let query = try SessionControlRequest.decode(data)
        switch query.action {
        case .delay, .traffic:
            // A slow node or a one-second traffic sample must not hold up stop or heartbeat.
            guard samples.wait(timeout: .now()) == .success else { throw SessionStoreError.occupied }
            defer { samples.signal() }
            let controller = try withActiveController(query, uid: uid) { $0 }
            let reply: SessionControlReply
            if query.action == .traffic { reply = try SessionControlReply(query, traffic: controller.trafficSample()) }
            else if let group = query.group, let member = query.member {
                reply = try SessionControlReply(query, delay: controller.measureDelay(group: group, member: member))
            } else { throw ServiceMessageError.invalid }
            return try withActiveController(query, uid: uid) { _ in reply }
        case .inspect, .setMode, .select, .unpin:
            return try withActiveController(query, uid: uid) { controller in
                if query.action != .inspect {
                    guard query.token == controlToken else { throw SessionStoreError.invalidTransition }
                    // A missing acknowledgement does not prove the core discarded a write.
                    controlToken = UUID()
                    if query.action == .unpin { try controller.clearAccessPin() }
                    else if let mode = query.mode { try controller.setMode(mode) }
                    else if let group = query.group, let member = query.member { try controller.select(group: group.coreName, member: member) }
                    else { throw ServiceMessageError.invalid }
                }
                return try SessionControlReply(query, state: controller.controls(token: controlToken))
            }
        }
    }

    private func release() {
        controlToken = UUID()
        retained = nil
        stopRequested = false
        restartRequired = false
        needsRecovery = false
        lastContact = 0
        idleToken = UUID()
    }

    private func maintain() {
        guard lock.try() else { return }
        defer { lock.unlock() }
        if restartRequired {
            // launchd KeepAlive replaces this daemon. The successor confirms
            // that the old launchctl group is gone before inspecting its job.
            restart()
            return
        }
        do {
            guard let held = retained else {
                if needsRecovery { try store().recoverInterruptedSession(); needsRecovery = false }
                return
            }
            guard let record = try held.current() else { release(); return }
            guard let run = record.run else {
                try held.recoverInterruptedSession()
                release()
                return
            }
            if run.stage == .active, !stopRequested, ProcessInfo.processInfo.systemUptime - lastContact < 30,
               (try? held.coreIsPresent(record)) == true { return }
            stopRequested = true
            try held.stopRunning(sessionID: record.sessionID, clientUID: record.clientUID, revision: run.revision)
            release()
        } catch {
            // Keep the durable journal and lease. A transient DNS or interface
            // failure can be retried after configd publishes its next state.
            needsRecovery = true
        }
    }
}
