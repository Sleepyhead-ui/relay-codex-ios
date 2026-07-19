import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        ZStack(alignment: .leading) {
            ConversationView()
                .disabled(store.sidebarOpen)
                .scaleEffect(store.sidebarOpen ? 0.985 : 1, anchor: .trailing)

            if store.sidebarOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { store.sidebarOpen = false } }
                    .transition(.opacity)
            }

            if store.sidebarOpen {
                SidebarView()
                    .frame(maxWidth: 356)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .background(RelayTheme.canvas)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.sidebarOpen)
        .fullScreenCover(isPresented: Binding(
            get: { store.needsConnection || store.showingConnection },
            set: { store.showingConnection = $0 }
        )) {
            ConnectionView(canDismiss: !store.needsConnection)
        }
        .sheet(isPresented: $store.showingSettings) { SettingsView() }
        .sheet(isPresented: $store.showingNewTask) {
            NewTaskView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $store.pendingApproval) { approval in ApprovalSheet(approval: approval) }
        .sheet(item: $store.sharedFile) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Relay", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
