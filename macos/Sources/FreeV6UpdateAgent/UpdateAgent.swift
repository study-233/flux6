import AppKit
import Sparkle
import FreeV6UpdateSupport

@MainActor final class UpdateAgent: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUUserDriver {
    private let operation = UUID()
    private var host: Bundle!
    private var channel: UpdateChannel!
    private var updater: SPUUpdater!
    private var standard: SPUStandardUserDriver!
    private var release: UpdateRelease?
    private var installationReply: ((SPUUserUpdateChoice) -> Void)?
    private var approved = false
    private var terminal = false
    private var cancelling = false
    private var cancellation: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try UpdatePipe.requireInheritedPipes()
            host = try UpdateHost.enclosingBundle()
            try UpdateHost.requireParent(of: host)
            #if FREEV6_UPDATE_PROBE
            let loopback = true
            #else
            let loopback = false
            guard host.bundleIdentifier == "dev.freev6.desktop" else { throw UpdateFailure.invalidHost }
            #endif
            channel = try UpdateChannel(info: host.infoDictionary ?? [:], allowLoopback: loopback)
            standard = SPUStandardUserDriver(hostBundle: host, delegate: nil)
            updater = SPUUpdater(hostBundle: host, applicationBundle: .main, userDriver: self, delegate: self)
            listen()
            try updater.start()
            updater.checkForUpdates()
        } catch { fail(error as? UpdateFailure ?? .invalidHost) }
    }

    private func send(_ kind: UpdateEvent.Kind, failure: UpdateFailure? = nil) {
        do { try UpdatePipe.write(UpdateEvent(kind, operation: operation, release: release, failure: failure), to: .standardOutput) }
        catch { if approved { stop() } else { cancel() } }
    }

    private func listen() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                while let reply = try UpdatePipe.read(UpdateReply.self, from: .standardInput) {
                    Task { @MainActor [weak self] in self?.receive(reply) }
                }
            } catch {}
            Task { @MainActor [weak self] in
                // After installation is authorized the host exits deliberately.
                guard let self, !self.approved else { return }
                self.cancel()
            }
        }
    }

    private func receive(_ reply: UpdateReply) {
        guard reply.operation == operation, !terminal else { fail(.transport); return }
        if !reply.install { cancel(); return }
        guard let pending = installationReply else { fail(.transport); return }
        installationReply = nil
        if reply.install {
            approved = true
            send(.installing)
            pending(.install)
        }
    }

    private func cancel() {
        guard !approved, !terminal, !cancelling else { return }
        cancelling = true
        if let reply = installationReply {
            installationReply = nil
            reply(.skip)
        } else {
            cancellation?()
        }
    }

    private func stop() {
        guard !terminal else { return }
        terminal = true
        NSApp.terminate(nil)
    }

    private func fail(_ failure: UpdateFailure) {
        send(.failed, failure: failure)
        stop()
    }

    func feedURLString(for updater: SPUUpdater) -> String? { channel.feed.absoluteString }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded, item.installationType == "application",
              !item.isDeltaUpdate, let url = item.fileURL, url.pathExtension == "zip",
              url.scheme == channel.feed.scheme, url.host?.isEmpty == false, url.user == nil, url.password == nil,
              item.contentLength > 0, item.contentLength <= 256 * 1024 * 1024,
              let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any],
              let encoded = enclosure["freev6:requirements"] as? String,
              let data = Data(base64Encoded: encoded) else { throw UpdateFailure.invalidFeed }
        let candidate = try UpdateRelease.decode(data, currentBuild: channel.build)
        guard String(candidate.build) == item.versionString else { throw UpdateFailure.incompatible }
        release = candidate
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        send(.checking)
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if cancelling { reply(.skip); return }
        guard release != nil else { reply(.skip); fail(.invalidFeed); return }
        send(.found)
        #if FREEV6_UPDATE_PROBE
        reply(.install)
        #else
        standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        #endif
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if cancelling { acknowledgement(); return }
        #if FREEV6_UPDATE_PROBE
        acknowledgement()
        send(.finished)
        stop()
        #else
        standard.showUpdateNotFoundWithError(error) { [weak self] in
            acknowledgement()
            self?.send(.finished)
            self?.stop()
        }
        #endif
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if cancelling { acknowledgement(); return }
        #if FREEV6_UPDATE_PROBE
        acknowledgement()
        fail(.invalidFeed)
        #else
        standard.showUpdaterError(error) { [weak self] in
            acknowledgement()
            self?.fail(.invalidFeed)
        }
        #endif
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        if cancelling { cancellation(); return }
        send(.downloading)
        standard.showDownloadInitiated(cancellation: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { cancellation = nil; standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if cancelling { reply(.skip); return }
        guard release != nil, installationReply == nil else { reply(.skip); fail(.invalidFeed); return }
        // The main app decides only after restoring its network session and
        // saving a durable upgrade record. Dismissal must cancel pending install.
        installationReply = reply
        send(.ready)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        send(.finished)
        stop()
    }

    func dismissUpdateInstallation() {
        standard.dismissUpdateInstallation()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if cancelling { send(.failed, failure: .cancelled); stop() }
        else if !approved { send(error == nil ? .finished : .failed, failure: error == nil ? nil : .invalidFeed); stop() }
    }
}

@main struct AgentMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = UpdateAgent()
        app.delegate = delegate
        app.run()
    }
}
