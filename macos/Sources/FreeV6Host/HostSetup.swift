import Foundation
import FreeV6Business
import FreeV6System

extension FreeV6HostCoordinator {
    func handleSetup(_ name: String) throws {
        guard settings.accepted else { throw HostFailure("notAccepted", "请先阅读并同意协议与隐私政策。") }
        if name == "setup.cancel" {
            setupTask?.cancel(); setupStatus = "正在暂停，已完成的步骤会保留。"; return
        }
        if name == "setup.finish" {
            guard setupTask == nil, setupStep == 5, setupError == nil else {
                throw HostFailure("prepare", "请先完成配置检查。")
            }
            settings.setupCompleted = true; return
        }
        guard name == "setup.start", setupTask == nil, !settings.busy, !settings.hasUnsavedRules,
              !network.mayOwnSession, service != .ready || network.phase == .idle else {
            throw HostFailure("busy", "请先确认网络会话已停止，再继续首次配置。")
        }
        settings.startup.cancelAutomatic()
        setupError = nil; settings.busy = true
        setupTask = Task { @MainActor [self] in
            defer { setupTask = nil; settings.busy = false; publish("state") }
            do {
                advanceSetup(0, "正在确认网络服务…")
                do { service = try await backend.health() } catch { service = .needsRepair }
                try Task.checkCancellation()
                if service != .ready {
                    advanceSetup(0, "请在系统窗口中授权安装网络服务。")
                    service = .managing
                    try await backend.prepare(.install)
                }
                await refresh(health: true, force: true)
                guard service == .ready, network.phase == .idle, !network.mayOwnSession else {
                    throw HostFailure("prepare", "网络服务尚未就绪。请检查状态后重试。")
                }
                let progress: @Sendable (WorkerProgress) -> Void = { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.setupTask != nil, !Task.isCancelled else { return }
                        if value.phase == "downloading" {
                            self.setupStatus = "已下载 " + ByteCountFormatter.string(fromByteCount: value.received, countStyle: .file)
                            self.publish("state")
                        }
                    }
                }
                for (step, command, label) in [(1, "preparation.core", "正在准备网络核心…"), (2, "preparation.geodata", "正在准备规则数据…")] {
                    try Task.checkCancellation()
                    advanceSetup(step, label)
                    try await settings.performPreparation("preparation.inspectResources", device: "", progress: { _ in }, willSave: {})
                    if step == 1 ? !settings.coreReady : !settings.geodataReady {
                        try await settings.performPreparation(command, device: "", progress: progress, willSave: {})
                    }
                }
                try Task.checkCancellation()
                advanceSetup(3, "正在准备账户，已有账户会自动复用…")
                if settings.preview {
                    try await settings.performPreparation("preparation.warpRegister", device: "", progress: { _ in }, willSave: {})
                } else if settings.stored?.cloud?.enabled != true {
                    settings.account = try await settings.registration.ensureRegistered(interactionAllowed: true, progress: progress)
                    await settings.refreshAccountSilently()
                }
                try Task.checkCancellation()
                advanceSetup(4, "正在检查连接配置…")
                let stored = try await worker.settings()
                settings.refreshStored(stored)
                let message = try await backend.check(stored, worker: worker, withService: true)
                try Task.checkCancellation()
                guard try await worker.settings().revision == stored.revision else { throw WorkerClientError.staleConfiguration }
                configurationCheckRevision = stored.revision; configurationCheckMessage = message
                advanceSetup(5, message)
                logs.record(.prepared)
            } catch {
                setupError = Task.isCancelled ? "已暂停。继续时会跳过已经准备好的资源。" : error.localizedDescription
                setupStatus = "请处理提示后继续配置。"
                await settings.refreshAccountSilently()
            }
        }
    }

    private func advanceSetup(_ step: Int, _ status: String) {
        setupStep = step; setupStatus = status; publish("state")
    }
}
