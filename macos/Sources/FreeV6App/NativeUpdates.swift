import AppKit
import Foundation
import FreeV6Business
import FreeV6Desktop
import FreeV6System
import FreeV6UpdateSupport

extension AppModel {
    func updateStore() throws -> UpdateTransactionStore {
        UpdateTransactionStore(root: try WorkerLocation.application().data)
    }

    func prepareUpdate(_ release: UpdateRelease, sourceBuild: UInt64) async throws {
        guard !terminating, !promptActive, !serviceBusy, !configurationBusy, !business.busy,
              !warp.busy, !warp.hasPending else { throw UpdateFailure.cancelled }
        let alert = NSAlert()
        alert.messageText = "安装更新并重新打开 FreeV6？"
        alert.informativeText = "安装前将保存配置并恢复当前网络。更新后，已安装的网络服务需要管理员重新登记。首次读取已有凭据时，钥匙串可能要求你为新版授权。"
        alert.addButton(withTitle: "安装并重新打开")
        alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { throw UpdateFailure.cancelled }
        if business.hasChanges {
            await business.save()
            guard business.error == nil, !business.hasChanges else { throw UpdateFailure.cancelled }
        }
        if let identity = try InstalledServiceStatus.identity() {
            try await network.disconnectBeforeUpdate(status: { id in
                try await Task.detached { try ServiceClient.sessionStatus(renewing: id, identity: identity) }.value
            }, stop: { id, revision in
                try await self.stop(id, revision: revision, identity: identity)
            })
        } else if network.mayOwnSession { throw UpdateFailure.installation }
        let store = try updateStore()
        let record = try UpdateTransaction(sourceBuild: sourceBuild, release: release)
        try await Task.detached { try store.save(record) }.value
        core.cancel()
        geodata.cancel()
        await session.shutdown()
        await logs.finishWrites()
    }

    func refreshUpdateRecovery() async {
        do {
            let store = try updateStore()
            let pendingRecord = try await Task.detached { try store.load() }.value
            guard let pending = pendingRecord else {
                updateRecoveryBlocksConnection = false
                updateRecoveryMessage = nil
                return
            }
            guard let buildText = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                  let build = UInt64(buildText) else { throw UpdateFailure.invalidHost }
            guard build >= pending.release.build else {
                updateRecoveryBlocksConnection = false
                updateRecoveryMessage = "上次应用升级尚未完成，可从 FreeV6 菜单重新检查更新。"
                return
            }
            updateRecoveryBlocksConnection = true
            let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
            try await Task.detached { try pending.verifyInstalledPayload(contents: contents, build: build) }.value
            if !serviceInstalled || serviceState == .ready {
                if serviceInstalled {
                    do {
                        try await Task.detached { try pending.verifyService(at: URL(fileURLWithPath: ServicePaths.executable)) }.value
                    } catch {
                        updateRecoveryMessage = "应用已更新，请从概览重新安装网络服务以完成升级。"
                        return
                    }
                }
                try await Task.detached { try store.clear(targetBuild: pending.release.build) }.value
                updateRecoveryBlocksConnection = false
                updateRecoveryMessage = "应用升级已完成。"
            } else {
                updateRecoveryMessage = "应用已更新，请从概览重新登记网络服务。完成后即可连接。"
            }
        } catch {
            updateRecoveryBlocksConnection = true
            updateRecoveryMessage = "无法确认上次升级结果，请检查网络服务或重新安装匹配的 DMG。"
        }
    }
}
