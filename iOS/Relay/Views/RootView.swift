import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: RelayStore
    @EnvironmentObject private var presentation: RelayPresentationStore

    var body: some View {
        ZStack(alignment: .leading) {
            ConversationView()
                .disabled(store.sidebarOpen)
                .scaleEffect(store.sidebarOpen ? 0.985 : 1, anchor: .trailing)

            if store.sidebarOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        RelayHaptics.selection()
                        withAnimation(.easeOut(duration: 0.2)) { store.sidebarOpen = false }
                    }
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
        .sheet(isPresented: $store.showingDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $store.showingNewTask) {
            NewTaskView()
                .relayResizableSheet()
        }
        .sheet(item: Binding(
            get: { store.pendingApproval },
            set: { _ in }
        )) { approval in ApprovalSheet(approval: approval) }
        .sheet(item: $presentation.sharedFile) { file in
            ShareSheet(items: [file.url])
        }
        .fullScreenCover(item: $store.imagePreview) { preview in
            ImagePreviewView(preview: preview)
        }
        .alert(errorPresentation?.title ?? "Relay", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            if let action = errorPresentation?.recoveryAction {
                Button(action.label) { performRecovery(action) }
            }
            if errorPresentation?.technicalDetails.nonEmpty != nil {
                Button("复制详情") {
                    UIPasteboard.general.string = errorPresentation?.technicalDetails
                    store.errorMessage = nil
                }
            }
            Button("关闭", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(errorPresentation?.message ?? "Relay 未能完成这次操作。")
        }
    }

    private var errorPresentation: RelayErrorPresentation? {
        store.errorMessage.map(RelayErrorPresentation.make)
    }

    private func performRecovery(_ action: RelayRecoveryAction) {
        store.errorMessage = nil
        switch action {
        case .reconnect:
            store.connect()
        case .editConnection:
            store.showingConnection = true
        case .openDiagnostics:
            DispatchQueue.main.async { store.showingDiagnostics = true }
        case .openSystemSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Keep presentation lightweight on iOS 16: the share controller should
        // not force the source view to recompute its entire transcript.
        controller.modalPresentationStyle = .pageSheet
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
