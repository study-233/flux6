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
    @Published public private(set) var readError: String?
    @Published public private(set) var selectionError: String?
    @Published public private(set) var modeError: String?
    @Published public private(set) var measurementError: String?
    public var error: String? { readError ?? selectionError ?? modeError ?? measurementError }
    @Published public private(set) var inspecting = false
    @Published public private(set) var writing = false
    @Published public private(set) var measuring = false
    @Published public private(set) var measuringMember: String?
    public private(set) var measuringGroup: SessionNodeGroup?
    @Published public private(set) var latency: [SessionNodeGroup: [String: CoreDelay]] = [:]
    @Published public private(set) var history: [TrafficReading] = []
    @Published public private(set) var currentTraffic: CoreTrafficSample?
    @Published public private(set) var trafficError: String?
    public private(set) var target: SessionControlTarget?
    @Published public private(set) var nodeCatalogRevision = 0
    private let preferences: NodePreferenceStore
    private var readID: UUID?
    private var writeID: UUID?
    private var sampleID: UUID?
    private var measurementID: UUID?

    public init(defaults: UserDefaults = .standard) { preferences = NodePreferenceStore(defaults) }

    public func bind(_ target: SessionControlTarget?) {
        guard self.target != target else { return }
        self.target = target
        readID = nil
        writeID = nil
        measurementID = nil
        state = nil
        readError = nil
        selectionError = nil
        modeError = nil
        measurementError = nil
        inspecting = false
        writing = false
        measuring = false
        measuringMember = nil
        measuringGroup = nil
        latency = [:]
        history = []
        hideTraffic()
    }

    public func inspect(using exchange: Exchange) async {
        guard let target, !writing, readID == nil else { return }
        let id = UUID()
        readID = id
        inspecting = true
        do {
            guard let snapshot = try await exchange(SessionControlRequest(target, .inspect)).state else {
                throw ServiceClientError.invalidReply
            }
            guard readID == id else { return }
            accept(snapshot)
            readError = nil
        } catch {
            guard readID == id else { return }
            state = nil
            readError = error.localizedDescription
        }
        readID = nil
        inspecting = false
    }

    @discardableResult
    public func change(_ request: SessionControlRequest, using exchange: Exchange) async -> Bool {
        guard !writing, request.target == target, let token = state?.token, request.token == token,
              [.setMode, .select, .unpin].contains(request.action) else { return false }
        let id = UUID()
        readID = nil
        inspecting = false
        writeID = id
        writing = true
        if request.action == .setMode { modeError = nil } else { selectionError = nil }
        do {
            guard let confirmed = try await exchange(request).state else { throw ServiceClientError.invalidReply }
            guard writeID == id else { return false }
            accept(confirmed)
            if let group = request.group, let member = request.member { saveNode(member, in: group) }
            if request.action == .unpin { saveNode(nil, in: .access) }
            writeID = nil
            writing = false
            return true
        } catch {
            guard writeID == id else { return false }
            if request.action == .setMode { modeError = error.localizedDescription }
            else { selectionError = error.localizedDescription }
            state = nil
            writeID = nil
            writing = false
            await inspect(using: exchange)
            return false
        }
    }

    private func accept(_ snapshot: SessionControlSnapshot) {
        if state?.groups != snapshot.groups, preferences.remember(snapshot.groups) { nodeCatalogRevision &+= 1 }
        state = snapshot
    }

    public func saveNode(_ member: String?, in group: SessionNodeGroup) {
        preferences.choose(member, group: group)
        selectionError = nil
        nodeCatalogRevision &+= 1
    }

    public func offlineGroup(_ group: SessionNodeGroup, names: [String], source: DesktopNodeGroup.Source) -> DesktopNodeGroup {
        DesktopNodeGroup(group: group, members: names, preferred: preferences.preferred(group, in: names), source: source)
    }

    public var previousGroups: [DesktopNodeGroup] {
        let catalog = preferences.previous
        return SessionNodeGroup.allCases.compactMap { group in
            catalog[group.rawValue].map { offlineGroup(group, names: $0, source: .previousSession) }
        }
    }

    public func preferredMember(_ group: SessionNodeGroup) -> String? {
        let names = state?.groups.first { $0.group == group }?.members ?? preferences.previous[group.rawValue] ?? []
        return preferences.preferred(group, in: names)
    }

    public func recentMembers(_ group: SessionNodeGroup, in members: [String]? = nil) -> [String] {
        let names = members ?? state?.groups.first { $0.group == group }?.members ?? preferences.previous[group.rawValue] ?? []
        return preferences.recent(group, in: names)
    }

    /// Consult the freshly confirmed members and token. A missing preference must never become a service request.
    public func restoration(for group: SessionNodeGroup) -> SessionControlRequest? {
        guard let state, let target, let list = state.groups.first(where: { $0.group == group }),
              preferences.hasPreference(group) else { return nil }
        if preferences.wantsAutomatic(group) {
            guard group == .access, list.automatic, list.preferred != nil else { return nil }
            return SessionControlRequest(target, .unpin, token: state.token)
        }
        guard let member = preferences.preferred(group, in: list.members) else {
            preferences.forget(group)
            selectionError = "上次首选已不在当前节点列表中，已采用本次会话的选择。"
            nodeCatalogRevision &+= 1
            return nil
        }
        guard member != (list.automatic ? list.preferred : list.selected) else { return nil }
        return SessionControlRequest(target, .select, token: state.token, group: group, member: member)
    }

    public func measure(_ group: SessionNodeGroup, members: [String], using exchange: Exchange) async {
        guard let target, let allowed = state?.groups.first(where: { $0.group == group })?.members,
              !measuring, !members.isEmpty, members.allSatisfy(allowed.contains) else { return }
        let id = UUID()
        measurementID = id
        measuringGroup = group
        measuring = true
        measurementError = nil
        for member in members {
            guard measurementID == id, !Task.isCancelled else { break }
            measuringMember = member
            do {
                let query = SessionControlRequest(target, .delay, group: group, member: member)
                guard let delay = try await exchange(query).delay else { throw ServiceClientError.invalidReply }
                guard measurementID == id else { return }
                latency[group, default: [:]][member] = delay
            } catch {
                guard measurementID == id else { return }
                measurementError = error.localizedDescription
                break
            }
        }
        if measurementID == id { cancelMeasurement() }
    }

    public func cancelMeasurement() {
        measurementID = nil
        measuringGroup = nil
        measuring = false
        measuringMember = nil
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
