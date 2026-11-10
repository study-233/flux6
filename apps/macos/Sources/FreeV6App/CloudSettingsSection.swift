import SwiftUI
import UniformTypeIdentifiers
import FreeV6Business

struct CloudSettingsSection: View {
    @ObservedObject var model: BusinessModel
    @ObservedObject var app: AppModel
    @State private var showURL = false
    @State private var showFile = false
    @State private var confirmClear = false
    @State private var panelError: String?

    var body: some View {
        Section("备用配置") {
            Text("获取节点和启用备用配置会立即保存，下次连接使用校园节点，无需注册 WARP。")
                .font(.callout).foregroundStyle(.secondary)
            if !model.cloudOpen {
                HStack {
                    Text("维护者公告尚未开放备用配置，或公告已过期。")
                    Button("刷新公告") { Task { await model.refreshNotice() } }.disabled(model.checkingNotice)
                    if model.checkingNotice { ProgressView().controlSize(.small) }
                }
                if let error = model.noticeError {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                }
            } else if model.snapshot?.chain?.enabled == true {
                Text("请先停用链式代理，再获取或启用备用配置。")
            }
            TextField("校园登录页地址", text: $model.portalAddress)
            if model.hasPortalChanges {
                Label("地址有未保存的更改，请点“保存地址”。", systemImage: "pencil")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存地址") { Task { await model.savePortalAddress() } }
                    .disabled(!model.hasPortalChanges)
                Button("获取备用配置") { Task { await model.changeCloud(.load(.portal(model.portalAddress))) } }
                    .disabled(!model.canFetchCloud || model.portalAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu("其他来源") {
                    Button("选择 YAML 文件…") { showFile = true }
                    Button("输入自定义地址…") { showURL = true }
                }.disabled(!model.canFetchCloud)
            }
            if let profile = model.snapshot?.cloud {
                Button("检查备用配置密钥…") { Task { await model.changeCloud(.checkKey) } }
                Toggle("下次连接使用备用配置", isOn: Binding(get: { profile.enabled }, set: { enabled in
                    Task { await model.changeCloud(.edit(.enable(enabled))) }
                })).disabled(!profile.enabled && !model.canFetchCloud)
                if let date = ISO8601DateFormatter().date(from: profile.updatedAt) {
                    Text("更新时间 " + date.formatted()).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("已保存 \(profile.names.count) 个校园节点") {
                    ForEach(profile.names, id: \.self) { Text(verbatim: $0).textSelection(.enabled) }
                }
                if !profile.ignored.isEmpty {
                    Text("已忽略来源中的系统配置：" + profile.ignored.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if profile.source != .file {
                        Button("刷新备用配置") { Task { await model.changeCloud(.load(.refresh)) } }.disabled(!model.canRefreshCloud)
                    }
                    Button("清除备用配置…", role: .destructive) { confirmClear = true }
                }
            }
            if let error = model.cloudError ?? panelError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            else if let message = model.cloudMessage { Text(message).foregroundStyle(.secondary) }
        }
        .disabled(!app.commandState.profileEditingAvailable)
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.yaml, .json, .plainText]) { result in
            panelError = nil
            switch result {
            case .success(let url): Task { await model.changeCloud(.load(.file(url))) }
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { panelError = "无法打开所选文件。" }
            }
        }
        .confirmationDialog("清除备用节点和自定义获取地址？", isPresented: $confirmClear) {
            Button("清除备用配置", role: .destructive) { Task { await model.changeCloud(.edit(.clear)) } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showURL) {
            ProfileAddressSheet(title: "备用配置来源", action: "获取") { address in
                guard app.commandState.profileEditingAvailable, model.canFetchCloud else {
                    return "当前无法获取备用配置。请刷新维护者公告并确认已停用链式代理。"
                }
                return await model.changeCloud(.load(.url(address)))
            }
        }
    }
}
