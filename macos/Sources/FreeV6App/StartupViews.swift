import ServiceManagement
import SwiftUI
import FreeV6Desktop

struct StartupNoticeView: View {
    @ObservedObject var model: AppModel
    var onAccept: (() -> Void)?
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "network").font(.system(size: 30)).foregroundStyle(.blue)
                    .frame(width: 58, height: 58).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 FreeV6").font(.title.bold())
                    Text("首次使用前，请阅读用户协议和隐私政策。").foregroundStyle(.secondary)
                }
            }
            if let notices = model.startup.notices {
                Picker("阅读文档", selection: $selected) {
                    Text("用户协议").tag(0)
                    Text("隐私政策").tag(1)
                }.pickerStyle(.segmented)
                ScrollView {
                    let document = selected == 0 ? notices.agreement : notices.privacy
                    NoticeText(source: document).padding(16)
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).id(selected)
                HStack {
                    Button("退出") { NSApp.terminate(nil) }
                    Spacer()
                    Button("同意用户协议与隐私政策") { (onAccept ?? model.acceptNotices)() }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("无法读取应用内的用户协议或隐私政策。请重新安装完整的 FreeV6。")
                Button("退出") { NSApp.terminate(nil) }
            }
        }.padding(24)
    }
}

private struct NoticeText: View {
    let source: String
    var body: some View {
        let blocks = source.replacingOccurrences(of: "</br>", with: "").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("<!--") }
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                if block == "---" { Divider() }
                else if block.hasPrefix("#") {
                    Text(String(block.drop(while: { $0 == "#" || $0 == " " })))
                        .font(block.hasPrefix("# ") ? .title2.bold() : .headline).accessibilityAddTraits(.isHeader)
                } else {
                    Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StartupSettingsView: View {
    @ObservedObject var startup: DesktopStartup
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section("启动") {
            Toggle("登录时打开 FreeV6", isOn: Binding(get: { startup.loginRequested }, set: { enabled in
                Task { await startup.setLogin(enabled) }
            })).disabled(interfaceFixture || startup.loginBusy)
            Text(interfaceFixture ? "隔离预览使用独立的启动偏好。" : (startup.loginError ?? startup.loginStatus?.description ?? "正在读取系统登录项…"))
                .font(.callout).foregroundStyle(.secondary)
            if startup.loginStatus == .needsApproval {
                Button("打开系统登录项设置…") { SMAppService.openSystemSettingsLoginItems() }
            } else if startup.loginRequested && (startup.loginStatus == .absent || startup.loginStatus == .moved) {
                Button("重新登记登录项") { Task { await startup.setLogin(true) } }.disabled(startup.loginBusy)
            } else if !startup.loginRequested, let actual = startup.loginStatus, actual != .absent {
                Button("移除已有登录项") { Task { await startup.setLogin(false) } }.disabled(startup.loginBusy)
            }
            Toggle("启动时收起主窗口", isOn: $startup.silent)
            Toggle("启动时自动连接", isOn: $startup.automatic)
            if let message = startup.automaticStatus { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .task { if !interfaceFixture { await startup.refreshLogin() } }
        .onChange(of: scenePhase) { _, phase in
            if !interfaceFixture && phase == .active { Task { await startup.refreshLogin() } }
        }
    }
}
