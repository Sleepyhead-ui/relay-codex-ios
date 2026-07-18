import SwiftUI

enum RelayTheme {
    static let accent = Color(red: 0.043, green: 0.498, blue: 0.388)
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.075, blue: 0.075, alpha: 1)
            : UIColor(red: 0.980, green: 0.980, blue: 0.976, alpha: 1)
    })
    static let sidebar = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
            : UIColor(red: 0.941, green: 0.941, blue: 0.933, alpha: 1)
    })
    static let elevated = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.14, alpha: 1) : .white
    })
    static let softFill = Color.primary.opacity(0.07)
    static let hairline = Color.primary.opacity(0.10)
    static let secondaryText = Color.secondary

    static let contentWidth: CGFloat = 760
    static let horizontalPadding: CGFloat = 18
    static let controlRadius: CGFloat = 8
}

struct RelayIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? RelayTheme.softFill : .clear)
            .clipShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func relayIconButton() -> some View {
        buttonStyle(RelayIconButtonStyle())
    }
}

