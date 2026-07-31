import SwiftUI

enum ConnectionField: Hashable {
    case computerName
    case endpoint
    case token
    case workingDirectory
}

struct ConnectionView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: ConnectionField?
    let canDismiss: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 16) {
                        RelayMark(size: 56)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("连接 Windows 电脑")
                                .font(.system(size: 28, weight: .semibold))
                            Text("输入 Relay Desktop 显示的连接地址和配对令牌，也可以使用相机扫描配对二维码。")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }
                    }

                    VStack(spacing: 18) {
                        RelayField(label: "电脑名称", placeholder: "Windows 电脑", text: $store.host.name, field: .computerName, focus: $focusedField)
                        RelayField(label: "连接地址", placeholder: "ws://100.x.x.x:8765", text: $store.host.endpoint, field: .endpoint, focus: $focusedField)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        RelaySecureField(label: "配对令牌", placeholder: "令牌", text: $store.token, field: .token, focus: $focusedField)
                        RelayField(label: "默认项目目录", placeholder: "C:\\Users\\you\\Projects", text: $store.host.workingDirectory, field: .workingDirectory, focus: $focusedField)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            focusedField = nil
                            store.connect()
                        } label: {
                            HStack {
                                Spacer()
                                if store.socket.state.isConnecting { ProgressView().tint(.white) }
                                Text(store.socket.state.isConnecting ? "正在连接" : "连接")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(.white)
                            .frame(height: 50)
                            .background(Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.socket.state.isConnecting)

                        Label("远程连接请使用 Tailscale 地址，不要把 Relay 端口直接暴露到公网。", systemImage: "lock.shield")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RelayTheme.canvas)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

struct RelayField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let field: ConnectionField
    let focus: FocusState<ConnectionField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            TextField(placeholder, text: $text)
                .focused(focus, equals: field)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(RelayTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: RelayTheme.controlRadius).stroke(RelayTheme.hairline) }
        }
    }
}

struct RelaySecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let field: ConnectionField
    let focus: FocusState<ConnectionField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            SecureField(placeholder, text: $text)
                .focused(focus, equals: field)
                .font(.system(size: 15, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(RelayTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: RelayTheme.controlRadius).stroke(RelayTheme.hairline) }
        }
    }
}
