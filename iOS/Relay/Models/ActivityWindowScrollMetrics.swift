import CoreGraphics

enum ActivityWindowScrollMetrics {
    static func isScrollable(contentHeight: CGFloat, viewportHeight: CGFloat, tolerance: CGFloat = 1) -> Bool {
        guard contentHeight.isFinite, viewportHeight > 0 else { return false }
        return contentHeight > viewportHeight + tolerance
    }

    static func isAtBottom(bottomY: CGFloat, viewportHeight: CGFloat, tolerance: CGFloat = 16) -> Bool? {
        guard bottomY.isFinite, abs(bottomY) < 1_000_000, viewportHeight > 0 else { return nil }
        return bottomY <= viewportHeight + tolerance
    }
}
