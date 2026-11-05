import Combine
import Foundation
import FreeV6System

public struct TrafficReading: Identifiable {
    public let id = UUID()
    public let date: Date
    public let sample: CoreTrafficSample
}

@MainActor public final class DesktopCoreControls: ObservableObject {
    public typealias Exchange = (SessionControlRequest) async throws -> SessionControlReply

    @Published public private(set) var state: SessionControlSnapshot?
    @Published public private(set) var error: String?
    @Published public private(set) var writing = false
    @Published public private(set) var measuring = false
    @Published public private(set) var latency: [SessionNodeGroup: [String: CoreDelay]] = [:]
    @Published public private(set) var history: [TrafficReading] = []
    @Published public private(set) var currentTraffic: CoreTrafficSample?
    @Published public private(set) var trafficError: String?
    public private(set) var target: SessionControlTarget?
    private let defaults: UserDefaults
    private var readID: UUID?
    private var writeID: UUID?
    private var sampleID: UUID?
    private var measurementID: UUID?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func bind(_ target: SessionControlTarget?) {
        guard self.target != target else { return }
        self.target = target
        readID = nil
        writeID = nil
        measurementID = nil
        state = nil
        error = nil
        writing = false
        measuring = false
        latency = [:]
        history = []
        hideTraffic()
    }

    public func inspect(using exchange: Exchange) async {
        guard let target, !writing, readID == nil else { return }
        let id = UUID()
        readID = id
        do {
            let reply = try await exchange(SessionControlRequest(target, .inspect))
            guard readID == id else { return }
            state = reply.state
        } catch {
            guard readID == id else { return }
            state = nil
            self.error = error.localizedDescription
        }
        readID = nil
    }

    @discardableResult
    public func change(_ request: SessionControlRequest, using exchange: Exchange) async -> Bool {
        guard !writing, request.target == target, let token = state?.token, request.token == token,
              [.setMode, .select, .unpin].contains(request.action) else { return false }
        let id = UUID()
        readID = nil
        writeID = id
        writing = true
        error = nil
        do {
            guard let confirmed = try await exchange(request).state else { throw ServiceClientError.invalidReply }
            guard writeID == id else { return false }
            state = confirmed
            if let group = request.group, let member = request.member {
                defaults.set(member, forKey: "preferredNode." + group.rawValue)
                let recent = [member] + recentMembers(group).filter { $0 != member }
                defaults.set(Array(recent.prefix(5)), forKey: historyKey(group))
            }
            if request.action == .unpin { defaults.removeObject(forKey: "preferredNode." + SessionNodeGroup.access.rawValue) }
            writeID = nil
            writing = false
            return true
        } catch {
            guard writeID == id else { return false }
            self.error = error.localizedDescription
            state = nil
            writeID = nil
            writing = false
            await inspect(using: exchange)
            return false
        }
    }

    private func historyKey(_ group: SessionNodeGroup) -> String { "recentNodes." + group.rawValue }
    public func preferredMember(_ group: SessionNodeGroup) -> String? { defaults.string(forKey: "preferredNode." + group.rawValue) }
    public func recentMembers(_ group: SessionNodeGroup) -> [String] {
        defaults.stringArray(forKey: historyKey(group)) ?? []
    }

    public func measure(_ group: SessionNodeGroup, members: [String], using exchange: Exchange) async {
        guard let target, let allowed = state?.groups.first(where: { $0.group == group })?.members,
              !measuring, !members.isEmpty, members.allSatisfy(allowed.contains) else { return }
        let id = UUID()
        measurementID = id
        measuring = true
        error = nil
        for member in members {
            guard measurementID == id, !Task.isCancelled else { break }
            do {
                let query = SessionControlRequest(target, .delay, group: group, member: member)
                guard let delay = try await exchange(query).delay else { throw ServiceClientError.invalidReply }
                guard measurementID == id else { return }
                latency[group, default: [:]][member] = delay
            } catch {
                guard measurementID == id else { return }
                self.error = error.localizedDescription
                break
            }
        }
        if measurementID == id { cancelMeasurement() }
    }

    public func cancelMeasurement() {
        measurementID = nil
        measuring = false
    }

    public func hideTraffic() {
        sampleID = nil
        if currentTraffic != nil { currentTraffic = nil }
        if trafficError != nil { trafficError = nil }
    }

    @discardableResult public func sample(using exchange: Exchange) async -> CoreTrafficSample? {
        guard let target, sampleID == nil else { return nil }
        let id = UUID()
        sampleID = id
        do {
            guard let sample = try await exchange(SessionControlRequest(target, .traffic)).traffic else { throw ServiceClientError.invalidReply }
            guard sampleID == id else { return nil }
            if history.count == 60 { history.removeFirst() }
            history.append(TrafficReading(date: Date(), sample: sample))
            currentTraffic = sample
            trafficError = nil
        } catch {
            guard sampleID == id else { return nil }
            currentTraffic = nil
            trafficError = error.localizedDescription
        }
        sampleID = nil
        return currentTraffic
    }
}
