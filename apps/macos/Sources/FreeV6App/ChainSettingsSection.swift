import SwiftUI
import FreeV6Business
import FreeV6Desktop

struct ChainSettingsSection: View {
    @ObservedObject var model: BusinessModel
    @ObservedObject var app: AppModel
    @State private var enteringURL = false
    let context: CommandContext
    @State private var confirmClear = false

    var body: some View {
        Section("链式代理") {
            Text("可从 Clash/mihomo YAML 导入 HTTP、SOCKS5、Shadowsocks、Trojan、VLESS 或 VMess 节点。每份文件或订阅最多 2 MiB、64 个节点。导入和启用操作会单独保存，下次连接生效。")
                .font(.callout).foregroundStyle(.secondary)
            if model.snapshot?.cloud?.enabled == true { Text("请先停用备用配置，再导入或启用链式代理。") }
            if let profile = model.snapshot?.chain {
                Toggle("下次连接使用链式代理", isOn: Binding(get: { profile.enabled }, set: { enabled in
                    Task { await model.changeChain(.enable(enabled)) }
                })).disabled(model.snapshot?.cloud?.enabled == true)
                DisclosureGroup("已导入 \(profile.names.count) 个节点") {
                    ForEach(profile.names, id: \.self) { Text($0).textSelection(.enabled) }
                }
                Button("检查链式代理密钥…") { Task { await model.changeChain(.checkKey) } }
            }
            HStack {
                DesktopCommandButton(.importChain, model: app, context: context)
                Button("导入订阅…") { enteringURL = true }.disabled(model.snapshot?.cloud?.enabled == true)
                if model.snapshot?.chain?.source == .url {
                    Button("刷新订阅") { Task { await model.changeChain(.load(.refresh)) } }.disabled(model.snapshot?.cloud?.enabled == true)
                }
                if model.snapshot?.chain != nil {
                    Button("清除…", role: .destructive) { confirmClear = true }
                }
            }
            if let failure = model.chainError { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            else if let message = model.chainMessage { Text(message).foregroundStyle(.secondary) }
        }
        .disabled(!app.commandState.profileEditingAvailable)
        .confirmationDialog("清除已导入的节点和订阅地址？", isPresented: $confirmClear) {
            Button("清除链式配置", role: .destructive) { Task { await model.changeChain(.clear) } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $enteringURL) {
            ProfileAddressSheet(title: "导入链式代理订阅", action: "导入") { address in
                guard app.commandState.profileEditingAvailable, model.snapshot?.cloud?.enabled != true else {
                    return "当前无法导入。请先载入代理规则并停用备用配置。"
                }
                return await model.changeChain(.load(.subscription(address)))
            }
        }
    }
}
