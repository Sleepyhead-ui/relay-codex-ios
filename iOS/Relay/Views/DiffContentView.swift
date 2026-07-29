import SwiftUI
import UIKit
import QuartzCore

struct DiffContentView: View {
    private let lines: [DiffLine]
    private let lineHeight: CGFloat = 19
    private var height: CGFloat { CGFloat(min(max(lines.count, 2), 18)) * lineHeight + 16 }

    init(source: String) {
        lines = DiffLine.parse(source)
    }

    var body: some View {
        GeometryReader { geometry in
            StableDiffScrollView(lines: lines, minimumWidth: max(geometry.size.width, 1))
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(RelayTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(RelayTheme.hairline, lineWidth: 1)
        }
    }
}

private struct StableDiffScrollView: UIViewRepresentable {
    let lines: [DiffLine]
    let minimumWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DiffScrollContainerView {
        let view = DiffScrollContainerView()
        view.scrollView.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: DiffScrollContainerView, context: Context) {
        view.update(lines: lines, minimumWidth: minimumWidth, preserving: context.coordinator.contentOffset)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var contentOffset = CGPoint.zero

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            contentOffset = scrollView.contentOffset
        }
    }
}

private final class DiffScrollContainerView: UIView {
    let scrollView = UIScrollView()
    private let canvas = DiffCanvasView()
    private var lines: [DiffLine] = []
    private var minimumWidth: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.decelerationRate = .normal
        scrollView.addSubview(canvas)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        layoutCanvas(preserving: scrollView.contentOffset)
    }

    func update(lines: [DiffLine], minimumWidth: CGFloat, preserving offset: CGPoint) {
        let changed = self.lines != lines
        self.lines = lines
        self.minimumWidth = minimumWidth
        if changed { canvas.lines = lines }
        layoutIfNeeded()
        layoutCanvas(preserving: offset)
    }

    private func layoutCanvas(preserving offset: CGPoint) {
        let contentWidth = max(minimumWidth, canvas.requiredWidth)
        let contentHeight = max(bounds.height, canvas.requiredHeight)
        let size = CGSize(width: contentWidth, height: contentHeight)
        if canvas.frame.size != size { canvas.frame = CGRect(origin: .zero, size: size) }
        if scrollView.contentSize != size { scrollView.contentSize = size }
        scrollView.alwaysBounceHorizontal = contentWidth > bounds.width + 0.5
        scrollView.alwaysBounceVertical = contentHeight > bounds.height + 0.5

        guard !scrollView.isDragging, !scrollView.isDecelerating else { return }
        let maximum = CGPoint(
            x: max(0, contentWidth - bounds.width),
            y: max(0, contentHeight - bounds.height)
        )
        let restored = CGPoint(x: min(max(0, offset.x), maximum.x), y: min(max(0, offset.y), maximum.y))
        if abs(scrollView.contentOffset.x - restored.x) > 0.5 || abs(scrollView.contentOffset.y - restored.y) > 0.5 {
            scrollView.setContentOffset(restored, animated: false)
        }
    }
}

private final class DiffCanvasView: UIView {
    static let lineHeight: CGFloat = 19
    private static let topInset: CGFloat = 8
    private static let gutterWidth: CGFloat = 24
    private static let trailingInset: CGFloat = 14
    private let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override class var layerClass: AnyClass { CATiledLayer.self }

    var lines: [DiffLine] = [] {
        didSet {
            requiredWidth = measuredWidth()
            requiredHeight = CGFloat(max(lines.count, 2)) * Self.lineHeight + Self.topInset * 2
            setNeedsDisplay()
        }
    }
    private(set) var requiredWidth: CGFloat = 1
    private(set) var requiredHeight: CGFloat = Self.lineHeight * 2 + Self.topInset * 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        if let tiledLayer = layer as? CATiledLayer {
            tiledLayer.tileSize = CGSize(width: 512, height: 512)
            tiledLayer.levelsOfDetail = 1
            tiledLayer.levelsOfDetailBias = 0
            tiledLayer.contentsScale = UIScreen.main.scale
        }
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !lines.isEmpty else { return }
        context.clear(rect)
        let first = max(0, Int(floor((rect.minY - Self.topInset) / Self.lineHeight)))
        let last = min(lines.count - 1, Int(ceil((rect.maxY - Self.topInset) / Self.lineHeight)))
        guard first <= last else { return }

        for index in first...last {
            let line = lines[index]
            let y = Self.topInset + CGFloat(index) * Self.lineHeight
            let row = CGRect(x: 0, y: y, width: bounds.width, height: Self.lineHeight)
            background(for: line.kind).setFill()
            context.fill(row)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foreground(for: line.kind),
            ]
            if let gutter = gutter(for: line.kind) {
                (gutter as NSString).draw(at: CGPoint(x: 8, y: y + 2), withAttributes: attributes)
            }
            (content(for: line) as NSString).draw(
                at: CGPoint(x: Self.gutterWidth, y: y + 2),
                withAttributes: attributes
            )
        }
    }

    private func measuredWidth() -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let longest = lines.reduce(CGFloat.zero) { width, line in
            max(width, (content(for: line) as NSString).size(withAttributes: attributes).width)
        }
        return ceil(Self.gutterWidth + longest + Self.trailingInset)
    }

    private func gutter(for kind: DiffLineKind) -> String? {
        switch kind { case .added: return "+"; case .removed: return "-"; default: return nil }
    }

    private func content(for line: DiffLine) -> String {
        let text = line.kind == .added || line.kind == .removed ? String(line.text.dropFirst()) : line.text
        return text.isEmpty ? " " : text
    }

    private func foreground(for kind: DiffLineKind) -> UIColor {
        switch kind {
        case .added: return .systemGreen
        case .removed: return .systemRed
        case .hunk: return .systemBlue
        case .header: return .secondaryLabel
        case .context: return UIColor.label.withAlphaComponent(0.78)
        }
    }

    private func background(for kind: DiffLineKind) -> UIColor {
        switch kind {
        case .added: return UIColor.systemGreen.withAlphaComponent(0.09)
        case .removed: return UIColor.systemRed.withAlphaComponent(0.09)
        case .hunk: return UIColor.systemBlue.withAlphaComponent(0.07)
        default: return .clear
        }
    }
}
