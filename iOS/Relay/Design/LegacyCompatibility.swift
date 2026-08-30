import SwiftUI

extension View {
    @ViewBuilder
    func relayScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func relayScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func relayResizableSheet(dragIndicatorVisible: Bool = true) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.medium, .large])
                .presentationDragIndicator(dragIndicatorVisible ? .visible : .hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func relayDarkNavigationBar() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.black.opacity(0.72), for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }
}

struct RelayLabeledRow<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            content
                .multilineTextAlignment(.trailing)
        }
    }
}
