import Combine
import Foundation
import FreeV6System

public enum DesktopNetworkPhase: Equatable, Sendable {
    case unknown, idle, connecting, running, disconnecting, recovering, occupied

    public var title: String {
        switch self {
        case .unknown: return "连接状态待确认"
        case .idle: return "未连接"
        case .connecting: return "正在连接…"
        case .running: return "已连接"
        case .disconnecting: return "正在断开…"
        case .recovering: return "网络需要恢复"
        case .occupied: return "其他用户正在使用 FreeV6"
        }
    }
    public var symbol: String {
        switch self {
        case .unknown, .recovering: return "exclamationmark.triangle"
        case .idle: return "network"
        case .connecting, .disconnecting: return "clock"
        case .running: return "checkmark.circle.fill"
        case .occupied: return "person.2"
        }
    }
    public var busy: Bool { self == .connecting || self == .disconnecting }
}

/// All three native command surfaces follow one authenticated service snapshot.
/// Closing a window does not own or cancel the heartbeat.
@MainActor public final class DesktopNetworkSession: ObservableObject {
    public typealias Status = (UUID?) async throws -> NetworkSessionReply
    public typealias Stop = (UUID, UInt64) async throws -> NetworkSessionReply

    @Published public private(set) var phase = DesktopNetworkPhase.unknown
    @Published public private(set) var error: String?
    @Published public private(set) var statusError: String?
    public private(set) var mayOwnSession = false {
        didSet {
            if mayOwnSession, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                 reason: "Maintain the active FreeV6 network session")
            } else if !mayOwnSession, let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
    }
    private var activity: NSObjectProtocol?
    private var snapshot: NetworkSessionReply?
    private var readID: UUID?

    public init() {}
    deinit { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
    public var runningTarget: SessionControlTarget? {
        guard phase == .running, let id = snapshot?.sessionID, let revision = snapshot?.revision else { return nil }
        return SessionControlTarget(sessionID: id, revision: revision)
    }
    public var canTargetSession: Bool { snapshot?.sessionID != nil && snapshot?.revision != nil }

    public func invalidate() {
        readID = nil
        phase = .unknown
        statusError = nil
    }

    private func accept(_ reply: NetworkSessionReply) {
        let previous = snapshot
        snapshot = reply
        statusError = nil
        switch reply.phase {
        case .stopped: phase = .idle
        case .occupied: phase = .occupied
        case .running: phase = .running
        case .recoveryRequired: phase = .recovering
        }
        mayOwnSession = reply.phase == .running || reply.phase == .recoveryRequired
        if previous?.phase == .running && reply.phase == .stopped && error == nil {
            error = "网络会话已由服务结束，请检查网络后重新连接。"
        }
    }

    public func refresh(using status: Status) async {
        guard !phase.busy, readID == nil else { return }
        let id = UUID()
        readID = id
        do {
            let reply = try await status(snapshot?.sessionID)
            guard readID == id else { return }
            accept(reply)
        } catch {
            guard readID == id else { return }
            phase = .unknown
            statusError = error.localizedDescription
        }
        readID = nil
    }

    public func connect(using start: (UUID) async throws -> NetworkSessionReply) async {
        guard phase == .idle, let token = snapshot?.idleToken else { return }
        readID = nil
        phase = .connecting
        mayOwnSession = true
        error = nil
        do {
            let active = try await start(token)
            guard active.phase == .running else { throw ServiceClientError.invalidReply }
            accept(active)
        } catch {
            self.error = error.localizedDescription
            phase = .unknown
        }
    }

    public func disconnect(using stop: Stop) async throws {
        guard !phase.busy, let id = snapshot?.sessionID, let revision = snapshot?.revision else {
            throw ServiceClientError.rejected("请先刷新并确认本人的网络会话。")
        }
        readID = nil
        phase = .disconnecting
        error = nil
        do {
            let stopped = try await stop(id, revision)
            guard stopped.phase == .stopped else { throw ServiceClientError.invalidReply }
            accept(stopped)
            error = nil
        } catch {
            self.error = error.localizedDescription
            phase = .unknown
            throw error
        }
    }

    /// Fresh status also handles reopening the app during the service's grace period.
    public func disconnectBeforeExit(status: Status, stop: Stop) async throws {
        guard !phase.busy else { throw ServiceClientError.rejected("请等待连接操作结束。") }
        readID = nil
        let expected = snapshot?.sessionID
        phase = .disconnecting
        do {
            let current = try await status(nil)
            accept(current)
            if current.phase == .stopped || current.phase == .occupied { return }
            guard current.sessionID != nil, expected == nil || expected == current.sessionID else {
                throw ServiceClientError.rejected("网络会话已经变化或正在恢复，请确认状态后再退出。")
            }
            try await disconnect(using: stop)
        } catch {
            self.error = error.localizedDescription
            if phase == .disconnecting { phase = .unknown }
            throw error
        }
    }
}
