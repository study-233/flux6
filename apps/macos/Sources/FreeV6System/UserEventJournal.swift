import Darwin
import Foundation

public enum EventSource: String, CaseIterable, Sendable {
    case app, service, worker, core

    public var title: String {
        switch self {
        case .app: return "应用"
        case .service: return "网络服务"
        case .worker: return "业务组件"
        case .core: return "网络核心"
        }
    }
}

public enum EventLevel: String, CaseIterable, Sendable {
    case info = "信息", warning = "提醒", error = "错误"
}

// Only these codes cross the journal/export boundary. Error descriptions, remote
// text, endpoints, node names and process output never enter the event type.
public enum DesktopEvent: String, Codable, Sendable {
    case opened = "应用已启动"
    case serviceReady = "已验证网络服务"
    case serviceMissing = "需要安装网络服务"
    case serviceFailure = "网络服务需要修复"
    case idle = "服务已确认网络会话停止"
    case connecting = "正在建立网络会话"
    case connected = "服务已确认网络会话运行"
    case disconnecting = "正在断开网络会话"
    case recovery = "网络仍需恢复"
    case occupied = "网络服务正由其他登录用户使用"
    case unknown = "无法确认网络会话状态"
    case operationFailed = "网络会话操作未完成"
    case settingsReady = "已载入本机配置"
    case settingsChanged = "已更新本机配置"
    case settingsFailure = "配置读写未完成"
    case profileFailure = "代理配置操作未完成"
    case accountFailure = "WARP 凭据操作未完成"
    case noticeOnline = "已更新维护者公告"
    case noticeCache = "已载入公告缓存"
    case noticeMissing = "维护者公告暂时不可用"
    case coreReady = "已校验本机网络核心"
    case coreNeeded = "需要下载网络核心"
    case coreFailure = "网络核心检查或下载未完成"
    case geodataReady = "已校验本机规则数据"
    case geodataNeeded = "需要准备规则数据"
    case geodataFailure = "规则数据检查或下载未完成"
    case prepared = "连接配置已通过检查"
    case preparationFailure = "连接配置检查失败"
    case controlFailure = "读取或更改核心状态失败"

    public var source: EventSource {
        switch self {
        case .opened, .prepared, .preparationFailure: return .app
        case .serviceReady, .serviceMissing, .serviceFailure, .idle, .connecting, .connected,
             .disconnecting, .recovery, .occupied, .unknown, .operationFailed: return .service
        case .settingsReady, .settingsChanged, .settingsFailure, .profileFailure, .accountFailure,
             .noticeOnline, .noticeCache, .noticeMissing: return .worker
        case .coreReady, .coreNeeded, .coreFailure, .geodataReady, .geodataNeeded, .geodataFailure,
             .controlFailure: return .core
        }
    }

    public var level: EventLevel {
        switch self {
        case .serviceFailure, .recovery, .operationFailed, .settingsFailure, .profileFailure,
             .accountFailure, .coreFailure, .geodataFailure, .preparationFailure, .controlFailure: return .error
        case .serviceMissing, .occupied, .unknown, .noticeMissing, .coreNeeded, .geodataNeeded: return .warning
        default: return .info
        }
    }
}

public struct UserEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let event: DesktopEvent

    public init(_ event: DesktopEvent, at date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.event = event
    }
}

public struct UserEventJournal: Sendable {
    public static let perSourceLimit = 128
    private let root: URL
    public init(root: URL) { self.root = root }

    private func openDirectory() throws -> SecureDirectory {
        let folder = try SecureDirectory(path: root.path, owner: geteuid(), create: true, searchAncestors: true)
        try folder.requirePrivate()
        guard let journal = try folder.privateChild("journal-v1", create: true) else { throw CocoaError(.fileNoSuchFile) }
        return journal
    }

    private func read(_ source: EventSource, from folder: SecureDirectory) throws -> [UserEvent] {
        guard let data = try folder.read(source.rawValue + ".events.json", limit: 64 * 1024) else { return [] }
        let rows = try JSONDecoder().decode([UserEvent].self, from: data)
        guard rows.count <= Self.perSourceLimit, rows.allSatisfy({ $0.event.source == source && $0.date.timeIntervalSince1970.isFinite }),
              Set(rows.map(\.id)).count == rows.count else { throw CocoaError(.fileReadCorruptFile) }
        return rows
    }

    // A delayed retry from another Flux6 process must not reintroduce events from before a clear.
    private func clearedThrough(in folder: SecureDirectory) throws -> Date {
        guard let data = try folder.read("cleared-through.json", limit: 128) else { return .distantPast }
        let cutoff = try JSONDecoder().decode(Date.self, from: data)
        guard cutoff.timeIntervalSinceReferenceDate.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        return cutoff
    }

    private func write(_ rows: [UserEvent], for source: EventSource, in folder: SecureDirectory) throws {
        let data = try JSONEncoder().encode(rows)
        try folder.publish(source.rawValue + ".events.json", mode: 0o600) { fd in
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        }
    }

    public func history() throws -> [UserEvent] {
        let folder = try openDirectory()
        let lock = try folder.acquireLock("events.lock")
        defer { try? lock.close() }
        try folder.discardStagingFiles()
        let cutoff = try clearedThrough(in: folder)
        return try EventSource.allCases.flatMap { try read($0, from: folder) }
            .filter { $0.date > cutoff }.sorted { $0.date < $1.date }
    }

    // Serialize the read/append/replace transaction across application processes.
    // Retrying a partially written batch is safe because entries have stable IDs.
    public func append(_ rows: [UserEvent]) throws {
        guard !rows.isEmpty else { return }
        let folder = try openDirectory()
        let lock = try folder.acquireLock("events.lock")
        defer { try? lock.close() }
        let cutoff = try clearedThrough(in: folder)
        for (source, incoming) in Dictionary(grouping: rows.filter { $0.date > cutoff }, by: { $0.event.source }) {
            let previous = try read(source, from: folder).filter { $0.date > cutoff }
            var ids = Set(previous.map(\.id))
            let additions = incoming.filter { ids.insert($0.id).inserted }
            guard !additions.isEmpty else { continue }
            let bounded = (previous + additions).sorted { $0.date < $1.date }.suffix(Self.perSourceLimit)
            try write(Array(bounded), for: source, in: folder)
        }
    }

    /// The lock and durable cutoff cover all four sources. A concurrent process can already have
    /// appended a newer event while this caller was waiting for its own writer to finish.
    @discardableResult public func clear(through requested: Date) throws -> [UserEvent] {
        let folder = try openDirectory()
        let lock = try folder.acquireLock("events.lock")
        defer { try? lock.close() }
        let cutoff = max(try clearedThrough(in: folder), requested)
        var survivors: [EventSource: [UserEvent]] = [:]
        for source in EventSource.allCases {
            let name = source.rawValue + ".events.json"
            guard try folder.withFile(name, { _ in true }) == true else { continue }
            // Validate every target before touching any. Leave links and unrelated files alone.
            try folder.requirePrivateFile(name)
            do { survivors[source] = try read(source, from: folder).filter { $0.date > cutoff } }
            catch is DecodingError { survivors[source] = [] }
            catch let error as CocoaError where error.code == .fileReadCorruptFile { survivors[source] = [] }
        }
        try folder.write("cleared-through.json", data: JSONEncoder().encode(cutoff), mode: 0o600)
        for (source, keep) in survivors {
            if keep.isEmpty { try folder.removeRegularFile(source.rawValue + ".events.json") }
            else { try write(keep, for: source, in: folder) }
        }
        return survivors.values.flatMap { $0 }.sorted { $0.date < $1.date }
    }
}
