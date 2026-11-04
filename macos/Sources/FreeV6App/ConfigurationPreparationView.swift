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
                       result.credentialRevision == model.warp.summary?.revision, !model.business.hasChanges {
                        Text("连接配置已生成").font(.headline)
                        Text("\(result.proxyCount) 个接入点 · \(result.ruleCount) 条规则").font(.callout)
                    } else { Text("设置或凭据已变化，需要重新检查。") }
                }
                DesktopCommandButton(.prepareConfiguration, model: model)
                if let reason = model.configurationPrerequisite, !model.configurationBusy {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.configurationError { Text(error).font(.callout).foregroundStyle(.red) }
                Text("按需读取钥匙串并检查配置结构，不会开启代理。连接与网络恢复功能仍在接入中。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}
