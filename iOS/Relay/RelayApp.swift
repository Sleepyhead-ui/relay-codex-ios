import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var store = RelayStore()

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
        }
    }
}
