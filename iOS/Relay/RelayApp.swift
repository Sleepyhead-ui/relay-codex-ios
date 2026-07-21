import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var store = RelayStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(RelayTheme.accent)
                .onOpenURL { store.consumePairingURL($0) }
                .task {
                    if !store.needsConnection, store.socket.state == .disconnected {
                        store.connect()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { store.applicationBecameActive() }
                    else if phase == .background { store.applicationEnteredBackground() }
                }
        }
    }
}
