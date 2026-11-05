import Combine
import Darwin
import Foundation
import FreeV6UpdateSupport
import FreeV6System

private final class UpdateAgentProcess: @unchecked Sendable {
    let events: AsyncThrowingStream<UpdateEvent, Error>
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "dev.freev6.update.reply")

    init(host: Bundle) throws {
        var continuation: AsyncThrowingStream<UpdateEvent, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { continuation = $0 }
        let executable = host.bundleURL.appendingPathComponent("Contents/Helpers/FreeV6UpdateAgent.app/Contents/MacOS/freev6-update-agent")
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw UpdateFailure.transport }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async { [self, continuation] in
            defer {
                try? output.fileHandleForReading.close()
                continuation?.finish()
            }
            do {
                while let event = try UpdatePipe.read(UpdateEvent.self, from: output.fileHandleForReading) {
                    guard case .enqueued = continuation?.yield(event) else { throw UpdateFailure.transport }
                }
            } catch { continuation?.finish(throwing: UpdateFailure.transport); cancel() }
        }
    }

    func answer(_ reply: UpdateReply) {
        writer.async { [self] in
            do { try UpdatePipe.write(reply, to: input.fileHandleForWriting) }
            catch { cancel() }
        }
    }

    func cancel() {
        writer.async { [self] in try? input.fileHandleForWriting.close() }
        if process.isRunning { process.terminate() }
    }
}

@MainActor public final class DesktopUpdater: ObservableObject {
    @Published public private(set) var busy = false
    @Published public private(set) var preparingInstallation = false
    @Published public private(set) var installationAuthorized = false
    @Published public private(set) var status = "手动检查更新"
    @Published public private(set) var error: String?
    private var agent: UpdateAgentProcess?
    private var task: Task<Void, Never>?
    private var operation: UUID?
    private var cancelRequested = false
    private var cancelSent = false

    public init() {}

    public func check(host: Bundle = .main, prepare: @escaping (UpdateRelease, UInt64) async throws -> Void,
                      install: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        cancelRequested = false
        cancelSent = false
        operation = nil
        status = "正在检查更新…"
        task = Task {
            defer { busy = false; preparingInstallation = false; agent = nil; task = nil }
            do {
                let channel = try UpdateChannel(info: host.infoDictionary ?? [:])
                let root = host.bundleURL
                let runningIdentity = try CodeIdentity.current()
                try await Task.detached {
                    let attributes = try root.resourceValues(forKeys: [.volumeIsReadOnlyKey])
                    guard attributes.volumeIsReadOnly != true, !root.pathComponents.contains("AppTranslocation") else { throw UpdateFailure.invalidHost }
                    guard try CodeIdentity.protectedFile(at: root) == runningIdentity else { throw UpdateFailure.invalidHost }
                }.value
                let child = try UpdateAgentProcess(host: host)
                agent = child
                var finished = false
                for try await event in child.events {
                    try Task.checkCancellation()
                    if let operation, operation != event.operation { throw UpdateFailure.transport }
                    operation = event.operation
                    sendCancellationIfNeeded()
                    if let release = event.release { try release.validate(currentBuild: channel.build) }
                    switch event.kind {
                    case .checking: status = "正在检查更新…"
                    case .found: status = "发现可用更新"
                    case .downloading: status = "正在下载并验证更新…"
                    case .ready:
                        guard let release = event.release, !preparingInstallation, !installationAuthorized else { throw UpdateFailure.transport }
                        if cancelRequested { continue }
                        preparingInstallation = true
                        status = "正在准备安装更新…"
                        do {
                            try await prepare(release, channel.build)
                            installationAuthorized = true
                            child.answer(UpdateReply(operation: event.operation, install: true))
                        } catch {
                            self.error = (error as? LocalizedError)?.errorDescription ?? "更新准备未完成，请查看网络状态或重试。"
                            cancelRequested = true
                            cancelSent = true
                            child.answer(UpdateReply(operation: event.operation, install: false))
                        }
                    case .installing:
                        guard installationAuthorized else { throw UpdateFailure.transport }
                        status = "正在安装更新…"
                        install()
                    case .finished: finished = true; status = "本次更新检查已结束"
                    case .failed: throw event.failure ?? UpdateFailure.installation
                    }
                }
                guard finished || installationAuthorized else { throw UpdateFailure.transport }
            } catch {
                agent?.cancel()
                installationAuthorized = false
                self.error = self.error ?? (error as? UpdateFailure)?.localizedDescription ?? "无法完成更新准备，请查看网络状态或重试。"
                status = "更新未完成"
            }
        }
    }

    private func sendCancellationIfNeeded() {
        guard cancelRequested, !cancelSent, let operation else { return }
        cancelSent = true
        agent?.answer(UpdateReply(operation: operation, install: false))
    }

    public func cancelForQuit() async {
        guard !installationAuthorized else { return }
        cancelRequested = true
        sendCancellationIfNeeded()
        await task?.value
    }
}
