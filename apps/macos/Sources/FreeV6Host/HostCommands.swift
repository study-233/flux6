import Foundation
import FreeV6Business
import FreeV6Desktop
import FreeV6System

extension FreeV6HostCoordinator {
    private func checkContext(_ envelope: [String: Any], token: Bool = false, checkConfig: Bool = true) async throws {
        // Other app instances can update worker settings without notifying our
        // in-memory snapshot. Validate the session after this suspension too.
        if checkConfig { settings.refreshStored(try await worker.settings()) }
        guard envelope.keys.contains("sessionId"),
              envelope["sessionId"] is NSNull || envelope["sessionId"] is String,
              (envelope["sessionId"] as? String)?.lowercased() == network.ownedTarget?.sessionID.uuidString.lowercased() else {
            throw HostFailure("staleSession", "会话已变化，请根据当前状态重试。")
        }
        if let revision = envelope["sessionRevision"] as? NSNumber, revision.uint64Value != network.ownedTarget?.revision {
            throw HostFailure("staleSession", "服务会话修订已变化，请刷新后重试。")
        }
        if token, network.phase == .running {
            guard let expected = envelope["controlToken"] as? String,
                  expected.lowercased() == controls.state?.token.uuidString.lowercased() else {
                throw HostFailure("staleSession", "节点列表已更新，请重新选择。")
            }
        }
        guard checkConfig else { return }
        guard envelope.keys.contains("revision"), let revision = (envelope["revision"] as? NSNumber)?.uint64Value,
              settings.stored?.revision == revision else {
            throw HostFailure("staleRevision", "已保存的配置发生变化，请核对后重试。")
        }
    }

    func perform(_ name: String, envelope: [String: Any]) async throws {
        let args = envelope["arguments"] as? [String: Any] ?? [:]
        if name.hasPrefix("setup.") { try handleSetup(name); return }
        if setupTask != nil && name != "refresh" {
            throw HostFailure("busy", "首次配置正在进行，请完成或暂停后再操作。")
        }
        if name == "refresh" {
            if settings.accepted { settings.refreshStored(try await worker.settings()) }
            await refresh(health: true, force: true)
            if service == .needsRepair || service == .ready && network.phase == .unknown {
                throw HostFailure("unavailable", error ?? network.statusError ?? "网络服务状态未确认。")
            }
            return
        }
        #if !FREEV6_RELEASE_HOST
        if name == "scenario", let isolatedSession = backend as? IsolatedHostSession {
            try await isolatedSession.scenario(args["name"] as? String ?? "")
            await refresh(health: true, force: true)
            return
        }
        #endif
        if name.hasPrefix("profile.") {
            guard settings.accepted else { throw HostFailure("notAccepted", "请先阅读并同意协议与隐私政策。") }
            try await checkContext(envelope)
        }
        if ["preparation.warpRegister", "preparation.warpDelete", "preparation.warpRetry", "preparation.core",
            "preparation.geodata"].contains(name), modeSource != .savedDefault || network.mayOwnSession {
            throw HostFailure("busy", "请先确认网络会话已停止，再修改连接资源或凭据。")
        }
        if try await settings.handle(name, arguments: args) {
            if name == "preparation.accept" { await refresh(health: true, force: true) }
            return
        }
        guard settings.accepted else { throw HostFailure("notAccepted", "请先阅读并同意协议与隐私政策。") }
        switch name {
        case "checkConfiguration":
            do {
                try await checkContext(envelope)
                guard canCheckConfiguration, let stored = settings.stored else {
                    throw HostFailure("busy", "请保存配置并确认网络会话已停止，再进行检查。")
                }
                checkingConfiguration = true
                configurationCheckRevision = stored.revision
                configurationCheckMessage = "正在检查连接配置…"
                publish("state")
                defer { checkingConfiguration = false }
                do { service = try await backend.health() }
                catch { service = .needsRepair; network.invalidate(); throw error }
                if service == .ready { await network.refresh { [backend] in try await backend.status($0) } }
                guard !network.mayOwnSession, service == .missing || (service == .ready && network.phase == .idle) else {
                    throw HostFailure("busy", "网络服务状态已变化，请重新确认。")
                }
                let message = try await backend.check(stored, worker: worker, withService: service == .ready)
                await settings.refreshAccountSilently()
                let latest = try await worker.settings()
                settings.refreshStored(latest)
                guard latest.revision == stored.revision else { throw WorkerClientError.staleConfiguration }
                configurationCheckMessage = message
                logs.record(.prepared)
            } catch {
                await settings.refreshAccountSilently()
                configurationCheckRevision = settings.stored?.revision
                configurationCheckMessage = error.localizedDescription
                logs.record(.preparationFailure)
                throw error
            }
        case "clearLogs":
            logs.clear(); await logs.finishWrites()
            if let clearError = logs.clearError { throw HostFailure("storage", clearError) }
        case "prepareService":
            let requested = args["action"] as? String ?? "install"
            guard let action = ServiceInstallationAction(rawValue: requested == "repair" ? "install" : requested),
                  !network.mayOwnSession, service != .ready || network.phase == .idle else {
                throw HostFailure("busy", "请先确认本人网络会话已停止。")
            }
            service = .managing; publish("state")
            do { try await backend.prepare(action) }
            catch { service = .needsRepair; throw error }
            await refresh(health: true, force: true)
        case "connect":
            try await checkContext(envelope)
            guard service == .ready, network.phase == .idle, !settings.blockedForConnection, let stored = settings.stored else {
                throw HostFailure("prepare", "请先准备服务并保存配置，再连接。")
            }
            let attempt = expectedAutomaticAttempt(envelope["id"] as? String)
            if let attempt, settings.startup.currentAttempt != attempt { throw CancellationError() }
            await network.connect { [backend, worker] token in
                try await backend.start(token, settings: stored, worker: worker, interactive: attempt == nil) { @MainActor [weak self] in
                    guard let self, self.network.phase == .connecting, self.settings.stored?.revision == stored.revision,
                          !self.settings.blockedForConnection, attempt == nil || self.settings.startup.currentAttempt == attempt else {
                        throw WorkerClientError.staleConfiguration
                    }
                }
            }
            await settings.refreshAccountSilently()
            guard network.phase == .running else {
                let reason = network.error ?? "服务未确认连接。"
                await refresh(health: true, force: true)
                throw HostFailure("connectFailed", reason)
            }
            started = Date()
            settings.setupCompleted = true
            await inspectControls(restoring: true)
        case "disconnect", "retryRecovery":
            try await checkContext(envelope, checkConfig: false)
            guard network.phase == .running || network.phase == .recovering, network.canTargetSession else {
                throw HostFailure("staleSession", "未确认本人的可恢复会话。")
            }
            await cancelDownload()
            do { try await network.disconnect(using: stop) }
            catch { await refresh(health: true, force: true); throw error }
            controls.bind(nil)
        case "setMode":
            try await checkContext(envelope, token: true)
            guard let mode = CoreMode(rawValue: args["mode"] as? String ?? ""),
                  let defaultMode = ProxyMode(rawValue: mode.rawValue), let stored = settings.stored, let source = modeSource else {
                throw HostFailure("unavailable", "当前无法更改工作模式。")
            }
            if source == .liveSession {
                guard let target = network.runningTarget, let state = controls.state else { throw ServiceClientError.unavailable }
                if state.mode != mode {
                    try await change(SessionControlRequest(target, .setMode, token: state.token, mode: mode))
                }
            }
            guard stored.settings.mode != defaultMode else { return }
            var preferences = stored.settings; preferences.mode = defaultMode
            do {
                settings.refreshStored(try await worker.save(preferences, revision: stored.revision))
                logs.record(.settingsChanged)
            } catch {
                if let current = try? await worker.settings() { settings.refreshStored(current) }
                if settings.stored?.settings.mode == defaultMode { return }
                let next = settings.stored?.settings.mode.title ?? "未知"
                throw HostFailure("defaultSave", source == .liveSession ? "会话已切换，已保存的下次模式为" + next + "。" : "下次模式未能保存，当前为" + next + "。")
            }
        case "setNode":
            try await checkContext(envelope, token: true)
            guard args.keys.contains("node"), args["node"] is NSNull || args["node"] is String,
                  let group = SessionNodeGroup(rawValue: args["group"] as? String ?? "access"),
                  let options = groups.first(where: { $0.group == group }) else {
                throw HostFailure("unavailable", "节点组当前不可用。")
            }
            let node = args["node"] as? String
            guard let source = modeSource, node.map(options.members.contains) ?? (group == .access) else {
                throw HostFailure("invalidNode", "此节点已不在当前配置中。")
            }
            if source == .savedDefault { controls.saveNode(node, in: group); return }
            guard let target = network.runningTarget, let state = controls.state else { throw ServiceClientError.unavailable }
            if let node { try await change(SessionControlRequest(target, .select, token: state.token, group: group, member: node)) }
            else { try await change(SessionControlRequest(target, .unpin, token: state.token)) }
        case "measure":
            guard downloadTask == nil else { throw HostFailure("busy", "请等待下载测速完成。") }
            try await checkContext(envelope, token: true, checkConfig: false)
            guard network.runningTarget != nil, let group = SessionNodeGroup(rawValue: args["group"] as? String ?? "access"),
                  let options = groups.first(where: { $0.group == group }),
                  let members = args["nodes"] as? [String], !members.isEmpty, members.count <= options.members.count,
                  members.allSatisfy(options.members.contains) else { throw HostFailure("invalidNode", "所选节点不可测速。") }
            await controls.measure(group, members: members) { [backend] in try await backend.control($0) }
            if let reason = controls.measurementError { throw HostFailure("measureFailed", reason) }
        case "download.start":
            try await checkContext(envelope, token: true, checkConfig: false)
            let members: [String]
            if let node = args["node"] as? String, args["nodes"] == nil { members = [node] }
            else if args["node"] == nil, let nodes = args["nodes"] as? [String] { members = nodes }
            else { throw HostFailure("invalidNode", "请选择要测速的节点。") }
            guard let target = network.runningTarget, downloadTask == nil, !controls.measuring,
                  let group = SessionNodeGroup(rawValue: args["group"] as? String ?? "access"),
                  let options = groups.first(where: { $0.group == group }),
                  !members.isEmpty, members.count <= options.members.count,
                  Set(members).count == members.count, members.allSatisfy(options.members.contains) else {
                throw HostFailure("invalidNode", "请连接后选择一个节点进行下载测速。")
            }
            startDownloads(target: target, group: group, members: members)
        case "download.cancel": await cancelDownload()
        default: throw HostFailure("unsupported", "当前版本不支持这个操作。")
        }
    }

    private func change(_ query: SessionControlRequest) async throws {
        let confirmed = await controls.change(query) { [backend] in try await backend.control($0) }
        guard confirmed else { throw HostFailure("unconfirmed", controls.error ?? "服务未确认更改。") }
    }
}
