import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss
    let canDismiss: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 16) {
                        RelayMark(size: 56)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connect to your Windows PC")
                                .font(.system(size: 28, weight: .semibold))
                            Text("Enter the address and token printed by Relay Bridge, or scan its QR code with the Camera app.")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }
                    }

                    VStack(spacing: 18) {
                        RelayField(label: "Computer name", placeholder: "Windows PC", text: $store.host.name)
                        RelayField(label: "WebSocket address", placeholder: "ws://100.x.x.x:8765", text: $store.host.endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        RelaySecureField(label: "Pairing token", placeholder: "Token", text: $store.token)
                        RelayField(label: "Default project folder", placeholder: "C:\\Users\\you\\Projects", text: $store.host.workingDirectory)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            store.connect()
                        } label: {
                            HStack {
                                Spacer()
                                if store.socket.state == .connecting { ProgressView().tint(.white) }
                                Text(store.socket.state == .connecting ? "Connecting" : "Connect")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(.white)
                            .frame(height: 50)
                            .background(Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.socket.state == .connecting)

                        Label("Use a Tailscale address for remote access. Do not expose this port directly to the public internet.", systemImage: "lock.shield")
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
            .background(RelayTheme.canvas)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

struct RelayField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            TextField(placeholder, text: $text)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            SecureField(placeholder, text: $text)
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

