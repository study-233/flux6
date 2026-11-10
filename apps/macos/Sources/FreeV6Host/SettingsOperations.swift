import Foundation
import FreeV6Business
import FreeV6Desktop
import FreeV6System

extension HostSettings {
    /// Update the shared settings window after connection preparation, without
    /// opening another authorization dialog or hiding an unsaved registration.
    func refreshAccountSilently() async {
        guard !preview else { return }
        pendingCredential = await registration.hasPendingCredential
        do {
            account = try await registration.inspect(interactionAllowed: false)
            accountStatus = account.map { "账户已保存 · " + $0.registeredAt } ?? "连接时将自动注册 WARP 账户"
        } catch { accountStatus = error.localizedDescription }
        if pendingCredential { accountStatus = "注册已完成，凭据等待保存。请重试保存，无需重新注册。" }
    }

    static let appIcons = ["cow", "orange", "prism", "four-color", "earth"]
    var appIcon: String {
        let saved = defaults.string(forKey: "appIcon") ?? "cow"
        return Self.appIcons.contains(saved) ? saved : "cow"
    }

    var preferencesMap: [String: Any] {
        ["appIcon": appIcon, "appearance": defaults.string(forKey: "appearance") ?? "system",
         "reduceMotion": defaults.bool(forKey: "reduceMotion"), "showMenuBar": defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true,
         "hideOnStart": startup.silent, "autoConnect": startup.automatic,
         "login": preview ? defaults.bool(forKey: "loginRequested") : startup.loginRequested,
         "loginStatus": preview ? "隔离登录偏好，系统登录项保持独立。" : (startup.loginError ?? startup.loginStatus?.description ?? ""),
         "needsLoginApproval": !preview && startup.loginStatus == .needsApproval]
    }

    var preparationMap: [String: Any] {
        ["accountStatus": accountStatus, "hasAccount": preview ? isolatedAccount : account != nil,
         "pendingCredential": pendingCredential, "core": coreStatus, "geodata": geodataStatus,
         "coreReady": coreReady, "geodataReady": geodataReady, "preview": preview,
         "active": preparationName ?? "", "canCancel": preparationCanCancel, "progress": preparationProgress]
    }

    var profileMap: [String: Any] {
        ["portal": stored?.portalHost ?? "", "chainNames": stored?.chain?.names ?? [], "chainEnabled": stored?.chain?.enabled ?? false,
         "chainSource": stored?.chain?.source.rawValue ?? "", "cloudNames": stored?.cloud?.names ?? [],
         "cloudSource": stored?.cloud?.source.rawValue ?? "", "cloudEnabled": stored?.cloud?.enabled ?? false, "cloudAllowed": cloudAllowed]
    }

    private var cloudAllowed: Bool {
        guard let notice, notice.cloudAllowed, let stamp = notice.fetchedAt,
              let date = ISO8601DateFormatter().date(from: stamp) else { return false }
        return (0...7 * 24 * 3600).contains(-date.timeIntervalSinceNow)
    }

    private var readIDs: [String] {
        guard let data = defaults.data(forKey: "maintainerNoticeReadIDs") else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    var noticeMap: [String: Any] {
        let read = Set(readIDs)
        let items = (notice?.items ?? []).map { item in
            ["id": item.id, "title": item.title, "body": item.body ?? "", "link": item.detailURL?.absoluteString ?? "",
             "published": item.published, "level": item.level.rawValue, "read": read.contains(item.id)] as [String: Any]
        }
        return ["items": items, "unread": items.filter { ($0["read"] as? Bool) == false }.count,
                "source": notice?.source.rawValue ?? "unavailable", "error": noticeError ?? ""]
    }

    func refreshNotice(online: Bool) async throws {
        do {
            let fetched = try await worker.maintainerNotice(refresh: online)
            if preview, fetched.source == .unavailable {
                let now = ISO8601DateFormatter().string(from: Date())
                let items = [
                    ["id":"isolated-profile", "title":"使用本地配置", "published":now, "body":"导入的节点在下次连接时生效。", "level":"info"],
                    ["id":"isolated-rules", "title":"规则更新", "published":now, "body":"保存代理规则后可查看配置页中的结果。", "level":"info"]]
                let data = try JSONSerialization.data(withJSONObject: ["source":"cache", "fetchedAt":now, "cloudAllowed":false, "items":items])
                notice = try JSONDecoder().decode(MaintainerNotice.self, from: data)
            } else { notice = fetched }
            noticeError = nil
        } catch {
            noticeError = "暂时无法读取维护者公告，请稍后重试。"
            throw SettingsFailure("暂时无法读取维护者公告，请稍后重试。")
        }
    }

    func markNotice(_ args: [String: Any]) throws {
        let ids = notice?.items.map(\.id) ?? []
        let requested = (args["all"] as? Bool == true) ? ids : [args["id"] as? String ?? ""]
        guard requested.allSatisfy(ids.contains) else { throw SettingsFailure("这条公告已被更新。") }
        let seen = readIDs.filter { !requested.contains($0) } + requested
        defaults.set(try JSONEncoder().encode(Array(seen.suffix(50))), forKey: "maintainerNoticeReadIDs")
    }

    func changePreference(_ a: [String: Any]) async throws {
        let field = a["field"] as? String
        if field == "appearance", let value = a["value"] as? String, ["system","light","dark"].contains(value) {
            defaults.set(value, forKey: "appearance"); return
        }
        if field == "appIcon" {
            guard let value = a["value"] as? String, Self.appIcons.contains(value) else {
                throw SettingsFailure("无效的图标。")
            }
            defaults.set(value, forKey: "appIcon"); return
        }
        guard let value = a["value"] as? Bool else { throw SettingsFailure("无效的偏好值。") }
        switch field {
        case "reduceMotion": defaults.set(value, forKey: "reduceMotion")
        case "showMenuBar": defaults.set(value, forKey: "showMenuBarExtra")
        case "autoConnect": startup.automatic = value
        case "hideOnStart": startup.silent = value
        case "login":
            if preview { defaults.set(value, forKey: "loginRequested") }
            else {
                await startup.setLogin(value)
                if let error = startup.loginError { throw SettingsFailure(error) }
            }
        default: throw SettingsFailure("未知偏好项。")
        }
    }

    func modifyProfile(_ action: String, _ args: [String: Any]) async throws {
        guard !busy else { throw SettingsFailure("请等待配置操作完成。") }
        guard let snapshot = stored else { throw SettingsFailure("请先载入已保存的配置。") }
        let chain = (args["type"] as? String) == "chain"
        guard chain || (args["type"] as? String) == "cloud" else { throw SettingsFailure("无效的配置类型。") }
        let source = args["source"] as? String
        let value = (args["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; defer { busy = false }
        do {
            if action == "profile.portal" {
                refreshStored(try await worker.changeCloud(.portal(value), settings: snapshot))
                return
            }
            if action == "profile.clear" {
                let updated = try await (chain ? worker.clearChain(settings: snapshot) : worker.changeCloud(.clear, settings: snapshot))
                refreshStored(updated); return
            }
            if action == "profile.enable" {
                guard let enabled = args["enabled"] as? Bool else { throw SettingsFailure("无效的启用状态。") }
                if enabled && (chain ? snapshot.cloud?.enabled == true : snapshot.chain?.enabled == true || !cloudAllowed) {
                    throw SettingsFailure("请先停用另一种出口，并确认备用配置已开放。")
                }
                let updated = try await (chain ? worker.setChainEnabled(enabled, settings: snapshot) : worker.changeCloud(.enable(enabled), settings: snapshot))
                refreshStored(updated); return
            }
            if action == "profile.checkKey" {
                try await (chain ? chainKey : cloudKey).checkAccess()
                return
            }
            guard action == "profile.import" else { throw SettingsFailure("未知配置操作。") }
            guard chain ? snapshot.cloud?.enabled != true : (cloudAllowed && snapshot.chain?.enabled != true) else {
                throw SettingsFailure("当前出口与所选配置不兼容。请先停用另一种出口，并确认公告已开放备用配置。")
            }
            if source == "url" {
                guard let url = URLComponents(string: value), ["http","https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host?.isEmpty == false else { throw SettingsFailure("请输入含主机名的 HTTP 或 HTTPS 地址。") }
            }
            guard source == "file" || source == "url" || source == "refresh" || (!chain && source == "portal") else {
                throw SettingsFailure("无效的节点来源。")
            }
            if source == "file", !value.hasPrefix("/") { throw SettingsFailure("请选择本地配置文件。") }
            let key = try await (chain ? chainKey : cloudKey).load(allowCreation: chain ? snapshot.chain == nil : snapshot.cloud == nil)
            let updated: SettingsSnapshot
            if chain {
                let input: ChainImportSource = source == "file" ? .file(URL(fileURLWithPath: value)) : source == "url" ? .subscription(value) : .refresh
                updated = try await worker.importChain(from: input, settings: snapshot, key: key)
            } else {
                let input: CloudImportSource
                switch source { case "file": input = .file(URL(fileURLWithPath: value))
                case "portal": input = .portal(value); case "url": input = .url(value); default: input = .refresh }
                updated = try await worker.importCloud(from: input, settings: snapshot, key: key)
            }
            refreshStored(updated); logs.record(.settingsChanged)
        } catch {
            logs.record(.profileFailure)
            if let error = error as? SettingsFailure { throw error }
            if let error = error as? CredentialError { throw error }
            if let error = error as? WorkerClientError { throw error }
            if let error = error as? WorkerRemoteError {
                if error.code == -32004 { throw SettingsFailure("已保存的配置在操作期间发生变化，请重新载入后再试。") }
                if error.message.contains("下载失败") { throw SettingsFailure("来源下载失败，请检查地址、网络和 2 MiB 大小限制。") }
                if error.message.contains("未开放") { throw SettingsFailure("备用配置当前未开放，请刷新维护者公告。") }
                if error.code == -32602 { throw SettingsFailure("来源或节点格式无效。请检查 HTTP(S) 地址、文件内容与节点数量后重试。") }
            }
            throw SettingsFailure("配置操作未完成。请检查来源访问权限、密钥和配置版本，再重试。")
        }
    }

    func prepare(_ name: String, arguments: [String: Any]) async throws {
        if name == "preparation.cancel" {
            guard preparationCanCancel else { throw SettingsFailure("当前没有可取消的准备操作。") }
            preparationCanCancel = false; preparationProgress = "正在取消…"; preparationTask?.cancel()
            return
        }
        guard !busy else { throw SettingsFailure("请等待当前准备操作完成。") }
        let device = (arguments["device"] as? String ?? "freev6-macos").trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "preparation.warpRegister" && (device.isEmpty || device.utf8.count > 128) {
            throw SettingsFailure("请输入不超过 128 字节的设备名称。")
        }
        if ["preparation.warpRegister","preparation.core","preparation.geodata"].contains(name), !preview {
            startPreparation(name, device: device)
            return
        }
        busy = true; onChange?(); defer { busy = false }
        try await performPreparation(name, device: device, progress: { _ in }, willSave: {})
    }

    private func startPreparation(_ name: String, device: String) {
        let id = UUID()
        busy = true; preparationID = id; preparationName = name; preparationCanCancel = true
        progressSequence = 0; preparationProgress = "正在准备…"
        let progress: @Sendable (WorkerProgress) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.preparationID == id, self.preparationCanCancel, value.sequence > self.progressSequence else { return }
                self.progressSequence = value.sequence
                if value.phase == "downloading" {
                    let received = ByteCountFormatter.string(fromByteCount: value.received, countStyle: .file)
                    let total = value.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: value.total, countStyle: .file) : ""
                    self.preparationProgress = "已下载 " + received + total
                } else { self.preparationProgress = name == "preparation.warpRegister" ? "正在注册设备…" : "正在校验资源…" }
                self.onChange?()
            }
        }
        let willSave: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.preparationID == id else { return }
                self.preparationCanCancel = false; self.preparationProgress = "正在保存到钥匙串…"; self.onChange?()
            }
        }
        preparationTask = Task {
            defer {
                preparationID = nil; preparationTask = nil; preparationName = nil
                busy = false; preparationCanCancel = false; preparationProgress = ""; onChange?()
            }
            do { try await performPreparation(name, device: device, progress: progress, willSave: willSave) }
            catch {
                let message = Task.isCancelled ? "操作已取消，可重新检查状态。" : error.localizedDescription
                switch name {
                case "preparation.core": coreStatus = message; logs.record(.coreFailure)
                case "preparation.geodata": geodataStatus = message; logs.record(.geodataFailure)
                default: if !pendingCredential { accountStatus = message }
                }
            }
        }
        onChange?()
    }

    func performPreparation(_ name: String, device: String,
                                    progress: @escaping @Sendable (WorkerProgress) -> Void,
                                    willSave: @escaping @Sendable () -> Void) async throws {
        if name == "preparation.core" || name == "preparation.geodata" || name == "preparation.inspectResources" {
            if preview {
                coreReady = true; geodataReady = true
                coreStatus = "隔离核心已就绪"; geodataStatus = "隔离规则数据已就绪"
                return
            }
            if name != "preparation.geodata" {
                let core = try await (name == "preparation.core" ? worker.downloadRuntime(progress: progress) : worker.runtimeStatus())
                coreReady = core.available; coreStatus = core.available ? "核心已校验 · " + core.version : "等待下载核心"
            }
            if name != "preparation.core" {
                let data = try await (name == "preparation.geodata" ? worker.prepareGeodata(progress: progress) : worker.geodataStatus())
                geodataReady = data.available; geodataStatus = data.available ? "规则数据已校验" : "等待下载规则数据"
            }
            return
        }
        if preview {
            switch name {
            case "preparation.warpRegister": isolatedAccount = true
            case "preparation.warpDelete": isolatedAccount = false
            case "preparation.warpInspect": break
            default: throw SettingsFailure("未知的隔离账户操作。")
            }
            accountStatus = isolatedAccount ? "隔离测试账户就绪" : "尚未建立隔离测试账户"
            return
        }
        do {
            switch name {
            case "preparation.warpInspect": account = try await registration.inspect()
            case "preparation.warpRegister":
                let current = try await registration.inspect()
                guard current == account else { throw SettingsFailure("账户状态已变化，请先重新检查账户。") }
                account = try await registration.register(name: device, replacing: current?.revision, willSave: willSave, progress: progress)
            case "preparation.warpRetry": account = try await registration.retrySave()
            case "preparation.warpDiscard": try await registration.discardPending()
            case "preparation.warpDelete":
                guard let revision = account?.revision else { throw SettingsFailure("请先检查现有账户。") }
                try await registration.delete(revision: revision); account = nil
            default: throw SettingsFailure("未知的账户操作。")
            }
            accountStatus = account.map { "账户已保存 · " + $0.registeredAt } ?? "连接时将自动注册 WARP 账户"
        } catch {
            pendingCredential = await registration.hasPendingCredential
            accountStatus = pendingCredential ? "注册已完成，凭据等待保存。" : error.localizedDescription
            logs.record(.accountFailure); throw SettingsFailure(accountStatus)
        }
        pendingCredential = await registration.hasPendingCredential
    }
}
