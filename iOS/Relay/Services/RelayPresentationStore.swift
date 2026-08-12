import Foundation
import Combine

@MainActor
final class RelayPresentationStore: ObservableObject {
    @Published var sharedFile: SharedFile?
}
