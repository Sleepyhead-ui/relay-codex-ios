import CoreGraphics

enum ConversationBottomVisibility {
    static func isAtBottom(bottomY: CGFloat, viewportHeight: CGFloat, tolerance: CGFloat = 12) -> Bool? {
        // PreferenceKey uses greatestFiniteMagnitude as its initial sentinel;
        // never interpret that value as a real on-screen position.
        guard viewportHeight > 0, bottomY.isFinite, abs(bottomY) < 1_000_000 else { return nil }
        return bottomY <= viewportHeight + tolerance
    }
}
