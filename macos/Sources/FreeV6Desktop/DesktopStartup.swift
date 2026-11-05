import Combine
import CryptoKit
import Foundation
import FreeV6System
import Network

public struct StartupNotices {
    public let agreement: String
    public let privacy: String
    fileprivate let revision: String

    public init(directory: URL) throws {
        func document(_ name: String) throws -> (String, SHA256.Digest) {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard !data.isEmpty, data.count < 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (text, SHA256.hash(data: data))
        }
        let terms = try document("agreement.md")
        let policy = try document("privacy.md")
        agreement = terms.0
        privacy = policy.0
        revision = Data(Array(terms.1) + Array(policy.1)).base64EncodedString()
    }
}

@MainActor public final class DesktopStartup: ObservableObject {
    private let defaults: UserDefaults
    private let login = LoginItemManager()
    private var loginRead = UUID()
    private var autoPending: Bool
    public private(set) var currentAttempt: UUID?
    public let notices: StartupNotices?
    @Published public private(set) var accepted: Bool
    @Published public private(set) var loginRequested: Bool
    @Published public private(set) var loginBusy = false
    @Published public private(set) var loginStatus: LoginItemStatus?
    @Published public private(set) var loginError: String?
    @Published public var silent: Bool { didSet { defaults.set(silent, forKey: "silentStart") } }
    @Published public var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "autoRunProxy")
            if !automatic { cancelAutomatic() }
        }
    }
    @Published public var automaticStatus: String?
    public var shouldStartHidden: Bool {
        accepted && silent && (defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true)
    }

    public init(defaults: UserDefaults, notices: StartupNotices?) {
        self.defaults = defaults
        self.notices = notices
        let previousConsent = notices.map { defaults.string(forKey: "acceptedNotices") == $0.revision } ?? false
        accepted = previousConsent
        loginRequested = defaults.bool(forKey: "loginRequested")
        silent = defaults.bool(forKey: "silentStart")
        automatic = defaults.bool(forKey: "autoRunProxy")
        autoPending = previousConsent && defaults.bool(forKey: "autoRunProxy")
    }
    public func acceptNotices() {
        guard let notices else { return }
        defaults.set(notices.revision, forKey: "acceptedNotices")
        accepted = true
    }
    public func cancelAutomatic() {
        autoPending = false
        currentAttempt = nil
        automaticStatus = nil
    }
    public func takeAutomaticAttempt() -> UUID? {
        guard autoPending, automatic, accepted else { return nil }
        autoPending = false
        let attempt = UUID()
        currentAttempt = attempt
        return attempt
    }
    public func waitForNetwork() async -> Bool {
        let monitor = NWPathMonitor()
        let paths = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied { continuation.yield(true); continuation.finish() }
            }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(30)); continuation.finish() } catch {}
            }
            continuation.onTermination = { _ in timeout.cancel(); monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.freev6.startup-path"))
        }
        for await ready in paths { return ready }
        return false
    }
    public func runAutomatic(prerequisite: () -> String?, waitForNetwork: () async -> Bool,
                             inspect: () async throws -> Void, connect: (UUID) async -> String?) async {
        guard let attempt = takeAutomaticAttempt() else { return }
        defer { currentAttempt = nil }
        if let reason = prerequisite() { automaticStatus = reason; return }
        automaticStatus = "自动连接正在等待可用网络…"
        let ready = await waitForNetwork()
        guard currentAttempt == attempt else { return }
        guard ready else { automaticStatus = "暂时没有可用网络，联网后可手动连接。"; return }
        if let reason = prerequisite() { automaticStatus = reason; return }
        do {
            try await inspect()
            guard currentAttempt == attempt else { return }
            if let reason = prerequisite() { automaticStatus = reason; return }
            let result = await connect(attempt)
            if currentAttempt == attempt { automaticStatus = result }
        } catch {
            if currentAttempt == attempt { automaticStatus = error.localizedDescription }
        }
    }
    public func refreshLogin() async {
        let read = UUID()
        loginRead = read
        do {
            let state = try await Task.detached { [login] in try login.status() }.value
            guard read == loginRead else { return }
            loginStatus = state
            loginError = nil
        } catch {
            guard read == loginRead else { return }
            loginStatus = nil
            loginError = error.localizedDescription
        }
    }
    public func setLogin(_ enabled: Bool) async {
        guard accepted, !loginBusy else { return }
        loginBusy = true
        defer { loginBusy = false }
        do {
            try await Task.detached { [login] in try login.setEnabled(enabled) }.value
            loginRequested = enabled
            defaults.set(enabled, forKey: "loginRequested")
            await refreshLogin()
        } catch { loginError = error.localizedDescription }
    }
}
