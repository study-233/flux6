import SwiftUI

struct ProfileAddressSheet: View {
    let title: String
    let action: String
    let submit: @MainActor (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var submitting = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("来源地址").font(.headline)
            SecureField("https://…", text: $address)
                .focused($focused).disabled(submitting).accessibilityLabel("来源地址")
                .accessibilityHint(error ?? "输入完整的 HTTP 或 HTTPS 地址")
                .onChange(of: address) { error = nil }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if submitting { ProgressView().controlSize(.small); Text("正在获取节点…").font(.callout) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                Button(action) { submitAddress() }.keyboardShortcut(.defaultAction)
                    .disabled(submitting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 416)
            .interactiveDismissDisabled(submitting)
            .onAppear { focused = true }
    }

    private func submitAddress() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitting else { return }
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty else {
            error = "请输入包含主机名的 HTTP 或 HTTPS 地址。"
            focused = true
            return
        }
        submitting = true
        error = nil
        Task { @MainActor in
            let failure = await submit(value)
            submitting = false
            if let failure { error = failure; focused = true }
            else { dismiss() }
        }
    }
}
