import SwiftUI

struct ApprovalSheet: View {
    @EnvironmentObject private var store: RelayStore
    let approval: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(approval.title)
                            .font(.system(size: 20, weight: .semibold))
                        Text(approval.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                if !approval.detail.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(approval.detail)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(13)
                    }
                    .frame(maxHeight: 180)
                    .background(RelayTheme.softFill)
                    .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                }

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        Task { await store.resolveApproval("decline") }
                    } label: {
                        Text("Deny")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RelayTheme.softFill)
                            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await store.resolveApproval("accept") }
                    } label: {
                        Text("Allow once")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .background(RelayTheme.elevated)
        .interactiveDismissDisabled()
    }
}

