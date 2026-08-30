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
    @State private var showingScanner = false
    let canDismiss: Bool

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 16) {
                        RelayMark(size: 56)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("连接 Windows 电脑")
                                .font(.system(size: 28, weight: .semibold))
                            Text("扫描 Relay Desktop 中的配对二维码，或手动输入连接信息。")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }
                    }

                    Button {
                        focusedField = nil
                        showingScanner = true
                    } label: {
                        Label("扫描配对二维码", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .foregroundStyle(RelayTheme.canvas)
                            .background(RelayTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        Rectangle().fill(RelayTheme.hairline).frame(height: 1)
                        Text("或手动输入")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Rectangle().fill(RelayTheme.hairline).frame(height: 1)
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
                            .foregroundStyle(canConnect ? RelayTheme.canvas : Color.secondary)
                            .frame(height: 50)
                            .background(canConnect ? Color.primary : RelayTheme.softFill)
                            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canConnect || store.socket.state.isConnecting)

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
            .relayScrollDismissesKeyboard()
            .background(RelayTheme.canvas)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                        .fontWeight(.semibold)
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                PairingScannerView { url in store.consumePairingURL(url) }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var canConnect: Bool {
        !store.host.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
