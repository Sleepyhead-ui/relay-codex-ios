import Foundation
import UIKit

enum TranscriptScrollCommandReason: String, Equatable {
    case initialThread
    case liveUpdate
    case outgoingMessage
    case outgoingMessageLayout
    case queuedFollowUp
    case bottomButton
    case keyboardTransition
}

struct TranscriptInitialScrollState: Equatable {
    private(set) var initializedThreadId: String?

    mutating func consume(threadId: String?) -> Bool {
        guard let threadId, threadId != initializedThreadId else { return false }
        initializedThreadId = threadId
        return true
    }
}

struct TranscriptScrollMetricsSnapshot: Equatable {
    let recordedAt: Date
    let scrollClass: String
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let distanceFromBottom: CGFloat
    let isDragging: Bool
    let isDecelerating: Bool
    let isAtBottom: Bool

    var json: JSONValue {
        .object([
            "recordedAt": .string(ISO8601DateFormatter().string(from: recordedAt)),
            "scrollClass": .string(scrollClass),
            "offsetY": .number(Double(offsetY)),
            "contentHeight": .number(Double(contentHeight)),
            "viewportHeight": .number(Double(viewportHeight)),
            "insetTop": .number(Double(insetTop)),
            "insetBottom": .number(Double(insetBottom)),
            "distanceFromBottom": .number(Double(distanceFromBottom)),
            "isDragging": .bool(isDragging),
            "isDecelerating": .bool(isDecelerating),
            "isAtBottom": .bool(isAtBottom)
        ])
    }
}

struct TranscriptScrollCommand: Identifiable, Equatable {
    let id: Int
    let recordedAt: Date
    let reason: TranscriptScrollCommandReason
    let animated: Bool
    let threadId: String?
    let isAtBottom: Bool
    let isUserScrolling: Bool

    var json: JSONValue {
        var value: [String: JSONValue] = [
            "id": .number(Double(id)),
            "recordedAt": .string(ISO8601DateFormatter().string(from: recordedAt)),
            "reason": .string(reason.rawValue),
            "animated": .bool(animated),
            "isAtBottom": .bool(isAtBottom),
            "isUserScrolling": .bool(isUserScrolling)
        ]
        if let threadId { value["threadId"] = .string(threadId) }
        return .object(value)
    }
}

final class TranscriptScrollDiagnostics {
    static let shared = TranscriptScrollDiagnostics()

    private(set) var latestMetrics: TranscriptScrollMetricsSnapshot?
    private(set) var recentCommands: [TranscriptScrollCommand] = []
    private var commandSequence = 0
    private var lastMetricsAt = Date.distantPast

    private init() {}

    func recordMetrics(_ metrics: TranscriptScrollMetricsSnapshot, force: Bool = false) {
        guard force || metrics.recordedAt.timeIntervalSince(lastMetricsAt) >= 0.2 else { return }
        latestMetrics = metrics
        lastMetricsAt = metrics.recordedAt
    }

    func recordCommand(
        reason: TranscriptScrollCommandReason,
        animated: Bool,
        threadId: String?,
        isAtBottom: Bool,
        isUserScrolling: Bool
    ) {
        commandSequence &+= 1
        recentCommands.insert(
            TranscriptScrollCommand(
                id: commandSequence,
                recordedAt: Date(),
                reason: reason,
                animated: animated,
                threadId: threadId,
                isAtBottom: isAtBottom,
                isUserScrolling: isUserScrolling
            ),
            at: 0
        )
        if recentCommands.count > 20 { recentCommands.removeLast(recentCommands.count - 20) }
    }

    func report() -> JSONValue {
        var value: [String: JSONValue] = [
            "commands": .array(recentCommands.map(\.json))
        ]
        if let latestMetrics { value["metrics"] = latestMetrics.json }
        return .object(value)
    }
}

final class ConversationScrollTracker {
    private weak var scrollView: UIScrollView?
    private var latestOffsetY: CGFloat?
    private var latestContentHeight: CGFloat?
    private var preservationBaselineOffsetY: CGFloat?
    private var preservationBaselineContentHeight: CGFloat?
    private var preservationFinishWorkItem: DispatchWorkItem?
    private var preservationCompletion: (() -> Void)?

    func attach(to scrollView: UIScrollView) {
        self.scrollView = scrollView
        update(from: scrollView, forceDiagnostics: true)
    }

    func detach(from scrollView: UIScrollView?) {
        guard self.scrollView === scrollView else { return }
        self.scrollView = nil
    }

    func update(from scrollView: UIScrollView, forceDiagnostics: Bool = false) {
        let contentHeightChanged = latestContentHeight.map {
            abs($0 - scrollView.contentSize.height) > 0.5
        } ?? true
        latestOffsetY = scrollView.contentOffset.y
        latestContentHeight = scrollView.contentSize.height
        restoreHistoryOffsetIfNeeded(in: scrollView)
        if contentHeightChanged, preservationCompletion != nil { schedulePreservationFinish() }

        let maxOffsetY = Self.maxOffsetY(in: scrollView)
        let distance = maxOffsetY - scrollView.contentOffset.y
        guard distance.isFinite else { return }
        TranscriptScrollDiagnostics.shared.recordMetrics(
            TranscriptScrollMetricsSnapshot(
                recordedAt: Date(),
                scrollClass: String(describing: type(of: scrollView)),
                offsetY: scrollView.contentOffset.y,
                contentHeight: scrollView.contentSize.height,
                viewportHeight: scrollView.bounds.height,
                insetTop: scrollView.adjustedContentInset.top,
                insetBottom: scrollView.adjustedContentInset.bottom,
                distanceFromBottom: distance,
                isDragging: scrollView.isDragging,
                isDecelerating: scrollView.isDecelerating,
                isAtBottom: distance <= 16
            ),
            force: forceDiagnostics
        )
    }

    @discardableResult
    func beginHistoryPreservation() -> Bool {
        guard latestOffsetY != nil, latestContentHeight != nil else { return false }
        preservationBaselineOffsetY = latestOffsetY
        preservationBaselineContentHeight = latestContentHeight
        preservationFinishWorkItem?.cancel()
        preservationFinishWorkItem = nil
        preservationCompletion = nil
        return true
    }

    func finishHistoryPreservationWhenSettled(completion: @escaping () -> Void) {
        preservationCompletion = completion
        schedulePreservationFinish()
    }

    private func schedulePreservationFinish() {
        preservationFinishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let completion = self.preservationCompletion
            self.preservationCompletion = nil
            self.preservationFinishWorkItem = nil
            self.preservationBaselineOffsetY = nil
            self.preservationBaselineContentHeight = nil
            completion?()
        }
        preservationFinishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func cancelHistoryPreservation() {
        preservationFinishWorkItem?.cancel()
        preservationFinishWorkItem = nil
        preservationCompletion = nil
        preservationBaselineOffsetY = nil
        preservationBaselineContentHeight = nil
    }

    private func restoreHistoryOffsetIfNeeded(in scrollView: UIScrollView) {
        guard let baselineOffsetY = preservationBaselineOffsetY,
              let baselineContentHeight = preservationBaselineContentHeight,
              scrollView.contentSize.height > baselineContentHeight + 1 else { return }
        let targetOffsetY = baselineOffsetY + scrollView.contentSize.height - baselineContentHeight
        guard abs(scrollView.contentOffset.y - targetOffsetY) > 0.5 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
            animated: false
        )
    }

    static func maxOffsetY(in scrollView: UIScrollView) -> CGFloat {
        max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
    }
}
