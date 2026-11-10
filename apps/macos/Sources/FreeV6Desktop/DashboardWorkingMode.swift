import Foundation

public enum DashboardWorkingMode: Equatable {
    case savedDefault, liveSession

    /// Only a confirmed idle session or a definitely absent service may edit the offline default.
    public static func source(phase: DesktopNetworkPhase, service: DesktopServiceState, mayOwnSession: Bool) -> Self? {
        guard !service.busy else { return nil }
        switch phase {
        case .running where service == .ready: return .liveSession
        case .idle where !mayOwnSession: return .savedDefault
        case .unknown where service == .missing && !mayOwnSession: return .savedDefault
        default: return nil
        }
    }
}
