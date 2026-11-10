import SwiftUI
import FreeV6Desktop
import FreeV6System

enum SetupDetail: String, CaseIterable, Identifiable {
    case service = "网络服务"
    case core = "网络核心"
    case account = "WARP 账户"
    case geodata = "规则数据"
    case configuration = "连接配置"
    var id: Self { self }
}

extension AppModel {
    var nextSetupDetail: SetupDetail {
        if serviceState == .missing || serviceState == .needsRepair { return .service }
        if core.package?.available != true { return .core }
        if business.snapshot?.cloud?.enabled != true && (warp.summary == nil || warp.hasPending) { return .account }
        if geodata.package?.available != true { return .geodata }
        return .configuration
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel

    @State private var showNotices = false
    @State private var showCatalog = false
    @AppStorage("maintainerNoticeReadIDs") private var readNoticeData = Data()

    private var unread: Int {
        let read = Set((try? JSONDecoder().decode([String].self, from: readNoticeData)) ?? [])
        return model.business.notice?.items.filter { !read.contains($0.id) }.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("仪表盘").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if model.dashboardDraft != nil {
                    Button("添加小组件", systemImage: "plus") { showCatalog = true }
                    Button("取消") { model.dashboardDraft = nil }
                    Button("完成") { model.saveDashboard() }.buttonStyle(.borderedProminent)
                } else {
                    Button { showNotices = true } label: {
                        Label(unread == 0 ? "公告" : "公告 · " + String(unread), systemImage: "bell")
                    }
                    Button("编辑布局", systemImage: "slider.horizontal.3") { model.dashboardDraft = model.dashboard }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusPanel
                    DashboardGrid(model: model, showCatalog: $showCatalog)
                }
                .frame(maxWidth: 1320, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCatalog) { WidgetCatalog(model: model) }
        .sheet(item: $model.setupDetail) { step in PreparationSheet(model: model, step: step) }
        .sheet(isPresented: $showNotices) {
            VStack(alignment: .trailing, spacing: 14) {
                MaintainerNoticeView(model: model.business)
                Button("完成") { showNotices = false }.keyboardShortcut(.defaultAction)
            }.padding(20).frame(width: 460, height: 350)
        }
    }

    @ViewBuilder private var statusPanel: some View {
        if let message = model.startup.automaticStatus {
            Label(message, systemImage: "power").font(.callout).foregroundStyle(.secondary)
        }
        if model.updater.busy || model.updater.error != nil || model.updateRecoveryMessage != nil {
            HStack {
                Label(model.updater.error ?? model.updateRecoveryMessage ?? model.updater.status, systemImage: "arrow.down.circle")
                    .textSelection(.enabled)
                if model.updateRecoveryMessage != nil && model.updateRecoveryBlocksConnection {
                    Spacer()
                    Button("查看网络服务") { model.setupDetail = .service }
                }
            }
        }
        let error = model.network.statusError ?? model.network.error ?? model.error
        if model.network.phase == .recovering || model.network.phase == .occupied || error != nil {
            HStack {
                Label(error ?? model.network.phase.title, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                Spacer()
                DesktopCommandButton(model.commandState.primaryCommand, model: model)
                DesktopCommandButton(.exportDiagnostics, model: model)
            }.padding(12).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        } else if model.serviceState == .missing || model.serviceState == .needsRepair ||
                    (model.network.phase == .idle && model.configurationPrerequisite != nil) {
            HStack(spacing: 12) {
                Image(systemName: "checklist").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("完成连接准备").font(.headline)
                    Text(model.serviceState == .ready ? (model.configurationPrerequisite ?? model.serviceStatus) : model.serviceStatus)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看步骤") { model.setupDetail = model.nextSetupDetail }
            }.padding(14).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct PreparationSheet: View {
    @ObservedObject var model: AppModel
    let step: SetupDetail
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SetupDetail?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("连接准备").font(.title2.bold())
                Spacer()
                if model.commandState.availability(.connect).enabled {
                    Button("连接") {
                        dismiss()
                        model.perform(.connect, in: .main(.overview), openWindow: openWindow)
                    }.keyboardShortcut(.defaultAction)
                } else {
                    Button("稍后继续") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SetupDetail.allCases) { item in
                        Button {
                            selection = item
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.rawValue).font(.headline)
                                Text(stepStatus(item)).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background((selection ?? step) == item ? Color.accentColor.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 148)
                Divider()
                ScrollView { detail(selection ?? step).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.padding(20).frame(width: 620, height: 420)
    }

    private func stepStatus(_ step: SetupDetail) -> String {
        switch step {
        case .service: model.serviceActionError == nil ? model.serviceStatus : "设置未完成"
        case .core: model.core.status
        case .account: model.business.snapshot?.cloud?.enabled == true ? "备用出口无需 WARP" : model.warp.status
        case .geodata: model.geodata.status
        case .configuration: model.configurationCheckStatus
        }
    }

    @ViewBuilder private func detail(_ step: SetupDetail) -> some View {
        switch step {
        case .service:
            VStack(alignment: .leading, spacing: 6) {
                Text("网络服务负责建立隧道，并在断开后恢复系统 DNS。")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = model.serviceActionError ?? model.error {
                    Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                }
                Button(model.serviceInstalled ? "修复网络服务…" : "安装网络服务…") {
                    Task { await model.manageService(.install) }
                }.disabled(!model.canManageService && !interfaceFixture)
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .core:
            RuntimePreparationView(model: model.core).disabled(interfaceFixture || model.configurationBusy)
        case .account:
            WarpAccountView(model: model.warp).disabled(interfaceFixture || model.serviceBusy || model.configurationBusy)
        case .geodata:
            GeodataPreparationView(model: model.geodata).disabled(interfaceFixture || model.configurationBusy)
        case .configuration:
            ConfigurationPreparationView(model: model)
            if model.business.snapshot == nil || model.business.hasChanges || model.business.snapshot?.cloud?.enabled == true {
                DesktopCommandButton(.showPage(.configuration), model: model)
            }
        }
    }
}

struct OverviewSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
