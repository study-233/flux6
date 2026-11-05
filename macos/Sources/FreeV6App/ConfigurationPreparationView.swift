import SwiftUI

struct ConfigurationPreparationView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("连接配置") {
            VStack(alignment: .leading, spacing: 12) {
                if model.configurationBusy {
                    HStack { ProgressView().controlSize(.small); Text("正在检查凭据、资源和配置…") }
                } else if let result = model.configurationSummary {
                    if result.settingsRevision == model.business.snapshot?.revision,
                       result.credentialRevision == model.activeCredentialRevision, !model.business.hasChanges {
                        Text(model.configurationCheckedByService ? "配置已通过核心检查" : "本机配置已检查").font(.headline)
                        Text("\(result.proxyCount) 个代理节点 · \(result.ruleCount) 条规则").font(.callout)
                    } else { Text("设置或凭据已变化，需要重新检查。") }
                }
                DesktopCommandButton(.prepareConfiguration, model: model)
                if let reason = model.configurationPrerequisite, !model.configurationBusy {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.configurationError { Text(error).font(.callout).foregroundStyle(.red) }
                Text(model.serviceState == .ready
                     ? "按需读取钥匙串，将缺少的核心与规则数据交给服务复验安装，再运行核心配置检查并清理临时配置。此操作不会开启代理。"
                     : "按需读取钥匙串并检查本机配置结构。网络服务就绪后再次检查，可完成资源交接与服务复验。此操作不会开启代理。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}
