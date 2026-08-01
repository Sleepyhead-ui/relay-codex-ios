import CoreGraphics

enum ConversationBottomVisibility {
    static func isAtBottom(bottomY: CGFloat, viewportHeight: CGFloat, tolerance: CGFloat = 12) -> Bool {
        guard viewportHeight > 0, bottomY.isFinite else { return true }
        return bottomY <= viewportHeight + tolerance
    }
}
