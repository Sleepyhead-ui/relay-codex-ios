import Combine

final class ComposerDraftState: ObservableObject {
    @Published var text: String

    init(text: String = "") {
        self.text = text
    }
}
