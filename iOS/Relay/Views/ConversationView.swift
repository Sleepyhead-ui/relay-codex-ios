import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var store: RelayStore
    @State private var isAtBottom = true
    @State private var isUserScrolling = false
    @State private var autoScrollScheduled = false
    @State private var visibleGroupLimit = 24
    @State private var activityPresentation: MobileActivityPresentation?
    @State private var keyboardTransitionID: UUID?
    @State private var preservingHistoryScroll = false
    @State private var initialScrollState = TranscriptInitialScrollState()
    @State private var scrollTracker = ConversationScrollTracker()

    private let bottomAnchor = "relay-conversation-bottom"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.55)
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let presentation = liveActivityPresentation {
                    MobileLiveActivityConsole(
                        presentation: presentation
                    ) {
                        activityPresentation = presentation
                    }
                    .padding(.horizontal, 12)
                }

                if store.showingArchivedThreads {
                    archivedBar
                } else {
                    ComposerView(draft: store.composerDraft)
                }
            }
        }
        .background(RelayTheme.canvas)
        .sheet(item: $activityPresentation) { presentation in
            MobileActivitySheet(
                presentation: presentation.isLive ? (liveActivityPresentation ?? presentation) : presentation
            )
        }
    }

    private var liveActivityPresentation: MobileActivityPresentation? {
        guard store.isRunning, let threadId = store.selectedThreadId else { return nil }
        let turnId = store.activeTurnId
        var metadata = turnId.flatMap { store.turnMetadata[$0] } ?? TurnMetadata()
        if metadata.startedAt == nil {
            metadata.startedAt = store.taskRunStates[threadId]?.startedAt
        }
        return MobileActivityPresentation(
            id: turnId ?? "starting.\(threadId)",
            feed: store.mobileActivityFeed(threadId: threadId, turnId: turnId),
            metadata: metadata,
            isLive: true,
            plan: store.activePlan
        )
    }

    private var archivedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 13, weight: .medium))
            Text("此任务已归档，仅供查看")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if let threadId = store.selectedThreadId {
                Button {
                    Task { await store.unarchiveThread(threadId) }
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.55) }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { store.sidebarOpen = true }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
            }
            .relayIconButton()
            .accessibilityLabel("Open conversations")

            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedThread?.title ?? "Relay")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 6, height: 6)
                    Text(connectionLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if store.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .frame(width: 26, height: 42)
            }

            Button {
                store.showingNewTask = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
            }
            .relayIconButton()
            .accessibilityLabel("New task")
        }
        .padding(.horizontal, 8)
        .frame(height: 58)
        .background(RelayTheme.canvas)
    }

    @ViewBuilder
    private var transcript: some View {
        if store.isLoadingThread {
            LoadingConversationView()
        } else if store.messages.isEmpty && store.currentQueuedFollowUps.isEmpty {
            EmptyConversationView()
        } else {
            ScrollViewReader { proxy in
                let window = store.transcriptWindow(limit: visibleGroupLimit)
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 30) {
                            if window.hasEarlierGroups || store.hasOlderTurns {
                                Button {
                                    revealEarlier(window: window, proxy: proxy)
                                } label: {
                                    HStack(spacing: 7) {
                                        if store.isLoadingOlderTurns {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        Text(earlierButtonLabel(window: window))
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundStyle(.secondary)
                                    .frame(height: 32)
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .disabled(store.isLoadingOlderTurns)
                            }

                            ForEach(window.groups) { group in
                                TurnGroupView(
                                    group: group,
                                    isLive: group.turnId == store.activeTurnId,
                                    store: store,
                                    onOpenActivity: { activityPresentation = $0 }
                                )
                                    .equatable()
                                    .id(group.id)
                            }

                            ForEach(store.currentQueuedFollowUps) { item in
                                QueuedFollowUpRow(item: item)
                                    .id("queued.\(item.id)")
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchor)
                        }
                        .frame(maxWidth: RelayTheme.contentWidth)
                        .padding(.horizontal, RelayTheme.horizontalPadding)
                        .padding(.top, 24)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                        .background {
                            ScrollActivityObserver(
                                tracker: scrollTracker,
                                onActiveChanged: { active in
                                    guard isUserScrolling != active else { return }
                                    isUserScrolling = active
                                },
                                onBottomChanged: { atBottom in
                                    guard !preservingHistoryScroll,
                                          keyboardTransitionID == nil else { return }
                                    if isAtBottom != atBottom { isAtBottom = atBottom }
                                }
                            )
                            .frame(width: 1, height: 1)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture { dismissKeyboard() }

                    if !isAtBottom {
                        Button {
                            isAtBottom = true
                            DispatchQueue.main.async {
                                scrollToBottom(proxy, animated: true, reason: .bottomButton)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay { Circle().stroke(RelayTheme.hairline, lineWidth: 1) }
                                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .onAppear { initializeTranscriptIfNeeded(proxy) }
                .onChange(of: store.selectedThreadId) { _ in
                    initializeTranscriptIfNeeded(proxy)
                }
                .onChange(of: store.transcriptRevision) { _ in
                    guard !preservingHistoryScroll,
                          isAtBottom,
                          !isUserScrolling,
                          !autoScrollScheduled else { return }
                    autoScrollScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        autoScrollScheduled = false
                        guard isAtBottom, !isUserScrolling else { return }
                        scrollToBottom(proxy, animated: !store.isRunning, reason: .liveUpdate)
                    }
                }
                .onChange(of: store.transcriptScrollRequest) { request in
                    guard request?.reason == .outgoingMessage else { return }
                    revealOutgoingMessage(proxy)
                }
                .onChange(of: store.currentQueuedFollowUps.map(\.id)) { _ in
                    guard isAtBottom, !isUserScrolling else { return }
                    DispatchQueue.main.async {
                        scrollToBottom(proxy, animated: true, reason: .queuedFollowUp)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                    pinBottomDuringKeyboardTransition(notification, proxy: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                    pinBottomDuringKeyboardTransition(notification, proxy: proxy)
                }
            }
        }
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        reason: TranscriptScrollCommandReason
    ) {
        TranscriptScrollDiagnostics.shared.recordCommand(
            reason: reason,
            animated: animated,
            threadId: store.selectedThreadId,
            isAtBottom: isAtBottom,
            isUserScrolling: isUserScrolling
        )
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func revealOutgoingMessage(_ proxy: ScrollViewProxy) {
        isUserScrolling = false
        isAtBottom = true

        // The running console and keyboard can both change the bottom inset in
        // the same update. Pin once after insertion and once after layout settles.
        DispatchQueue.main.async {
            scrollToBottom(proxy, animated: false, reason: .outgoingMessage)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard isAtBottom, !isUserScrolling else { return }
            scrollToBottom(proxy, animated: false, reason: .outgoingMessageLayout)
        }
    }

    private func initializeTranscriptIfNeeded(_ proxy: ScrollViewProxy) {
        guard let threadId = store.selectedThreadId,
              initialScrollState.consume(threadId: threadId) else { return }
        isAtBottom = true
        visibleGroupLimit = 24
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard initialScrollState.initializedThreadId == threadId else { return }
            scrollToBottom(proxy, animated: false, reason: .initialThread)
        }
    }

    private func earlierButtonLabel(window: TranscriptWindow) -> String {
        if store.isLoadingOlderTurns { return "正在加载更早对话" }
        return window.hasEarlierGroups ? "显示更早的对话" : "加载更早对话"
    }

    private func revealEarlier(window: TranscriptWindow, proxy: ScrollViewProxy) {
        let anchor = window.groups.first?.id
        let wasAtBottom = isAtBottom
        let hasNativeMetrics = scrollTracker.beginHistoryPreservation()
        preservingHistoryScroll = true
        if window.hasEarlierGroups {
            visibleGroupLimit += 24
            if !hasNativeMetrics { restore(anchor: anchor, proxy: proxy) }
            finishHistoryScrollPreservation(wasAtBottom: wasAtBottom)
            return
        }
        Task { @MainActor in
            await store.loadOlderTurns()
            visibleGroupLimit += 12
            if !hasNativeMetrics { restore(anchor: anchor, proxy: proxy) }
            finishHistoryScrollPreservation(wasAtBottom: wasAtBottom)
        }
    }

    private func finishHistoryScrollPreservation(wasAtBottom: Bool) {
        scrollTracker.finishHistoryPreservationWhenSettled {
            preservingHistoryScroll = false
            isAtBottom = wasAtBottom
        }
    }

    private func pinBottomDuringKeyboardTransition(
        _ notification: Notification,
        proxy: ScrollViewProxy
    ) {
        guard isAtBottom || keyboardTransitionID != nil else { return }
        let transitionID = UUID()
        keyboardTransitionID = transitionID
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25
        let animation = keyboardAnimation(notification, duration: duration)

        DispatchQueue.main.async {
            guard keyboardTransitionID == transitionID else { return }
            TranscriptScrollDiagnostics.shared.recordCommand(
                reason: .keyboardTransition,
                animated: true,
                threadId: store.selectedThreadId,
                isAtBottom: isAtBottom,
                isUserScrolling: isUserScrolling
            )
            withAnimation(animation) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.04) {
            guard keyboardTransitionID == transitionID else { return }
            isAtBottom = true
            keyboardTransitionID = nil
        }
    }

    private func keyboardAnimation(_ notification: Notification, duration: Double) -> Animation {
        let rawCurve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
            .intValue
        switch rawCurve.flatMap(UIView.AnimationCurve.init(rawValue:)) {
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        case .linear: return .linear(duration: duration)
        default: return .easeInOut(duration: duration)
        }
    }

    private func restore(anchor: String?, proxy: ScrollViewProxy) {
        guard let anchor else { return }
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    private var connectionColor: Color {
        if store.socket.state == .connected, store.isSelectedThreadUpstreamRetrying { return .orange }
        switch store.socket.state {
        case .connected: return RelayTheme.accent
        case .connecting, .reconnecting: return .orange
        case .disconnected, .failed: return .secondary
        }
    }

    private var connectionLabel: String {
        switch store.socket.state {
        case .connected:
            return store.isSelectedThreadUpstreamRetrying ? "Codex 上游服务正在重试" : store.host.name
        case .connecting: return "正在连接 Windows"
        case .reconnecting(let attempt): return "正在重新连接 Windows · \(attempt)"
        case .disconnected: return "Windows 离线"
        case .failed: return "Windows 连接已断开"
        }
    }
}

private struct ScrollActivityObserver: UIViewRepresentable {
    let tracker: ConversationScrollTracker
    let onActiveChanged: (Bool) -> Void
    let onBottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tracker: tracker,
            onActiveChanged: onActiveChanged,
            onBottomChanged: onBottomChanged
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onActiveChanged = onActiveChanged
        context.coordinator.onBottomChanged = onBottomChanged
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
    }

    final class Coordinator: NSObject {
        let tracker: ConversationScrollTracker
        var onActiveChanged: (Bool) -> Void
        var onBottomChanged: (Bool) -> Void
        private(set) weak var scrollView: UIScrollView?
        private var isActive = false
        private var resetWorkItem: DispatchWorkItem?
        private var lastAtBottom: Bool?

        init(
            tracker: ConversationScrollTracker,
            onActiveChanged: @escaping (Bool) -> Void,
            onBottomChanged: @escaping (Bool) -> Void
        ) {
            self.tracker = tracker
            self.onActiveChanged = onActiveChanged
            self.onBottomChanged = onBottomChanged
        }

        func attach(to view: UIView) {
            guard scrollView == nil else { return }
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scrollView = candidate as? UIScrollView {
                    self.scrollView = scrollView
                    tracker.attach(to: scrollView)
                    scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
                    scrollView.addObserver(self, forKeyPath: #keyPath(UIScrollView.contentOffset), options: [.new], context: nil)
                    scrollView.addObserver(self, forKeyPath: #keyPath(UIScrollView.contentSize), options: [.new], context: nil)
                    publishMetrics(for: scrollView)
                    return
                }
                ancestor = candidate.superview
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                resetWorkItem?.cancel()
                resetWorkItem = nil
                guard !isActive else { return }
                isActive = true
                onActiveChanged(true)
            case .ended, .cancelled, .failed:
                resetWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in self?.finishWhenIdle() }
                resetWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
            default:
                break
            }
        }

        private func finishWhenIdle() {
            guard isActive else { return }
            if scrollView?.isDragging == true || scrollView?.isDecelerating == true {
                let workItem = DispatchWorkItem { [weak self] in self?.finishWhenIdle() }
                resetWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
                return
            }
            isActive = false
            onActiveChanged(false)
        }

        override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard let scrollView = object as? UIScrollView else { return }
            if keyPath == #keyPath(UIScrollView.contentOffset) || keyPath == #keyPath(UIScrollView.contentSize) {
                publishMetrics(for: scrollView)
            }
        }

        private func publishMetrics(for scrollView: UIScrollView) {
            tracker.update(from: scrollView)
            let maxOffsetY = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let distance = maxOffsetY - scrollView.contentOffset.y
            guard distance.isFinite else { return }
            let atBottom = distance <= 16
            guard lastAtBottom != atBottom else { return }
            lastAtBottom = atBottom
            tracker.update(from: scrollView, forceDiagnostics: true)
            onBottomChanged(atBottom)
        }

        deinit {
            resetWorkItem?.cancel()
            if let scrollView {
                scrollView.removeObserver(self, forKeyPath: #keyPath(UIScrollView.contentOffset))
                scrollView.removeObserver(self, forKeyPath: #keyPath(UIScrollView.contentSize))
            }
            tracker.detach(from: scrollView)
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
        }
    }
}

private struct LoadingConversationView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading conversation")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Spacer().frame(height: 68)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyConversationView: View {
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            RelayMark(size: 52)
            VStack(spacing: 7) {
                Text("What should Codex work on?")
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(projectLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Spacer().frame(height: 68)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectLabel: String {
        let directory = store.currentWorkingDirectory
        return directory.isEmpty ? "已连接到 \(store.host.name)" : directory.lastPathComponentForDisplay
    }
}

struct RelayMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.primary)
            Image(systemName: "chevron.right")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(RelayTheme.canvas)
                .offset(x: -size * 0.05)
            Capsule()
                .fill(RelayTheme.canvas)
                .frame(width: size * 0.24, height: max(2, size * 0.055))
                .offset(x: size * 0.19, y: size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
