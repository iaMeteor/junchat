//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import MatrixRustSDK
import OrderedCollections
import SwiftUI

/// A table view cell that displays a timeline item in a room. The cell is intended
/// to be configured to display a SwiftUI view and not use any UIKit.
class TimelineItemCell: UITableViewCell {
    static let reuseIdentifier = "TimelineItemCell"
    
    // periphery:ignore - retaining purpose
    var item: RoomTimelineItemViewState?
    
    override func prepareForReuse() {
        item = nil
    }
}

/// A table view cell that displays member typing notifications. The cell is intended
/// to be configured to display a SwiftUI view and not use any UIKit.
class TimelineTypingIndicatorCell: UITableViewCell {
    static let reuseIdentifier = "TimelineTypingIndicatorCell"
}

class TypingMembersObservableObject: ObservableObject {
    @Published var members: [String] = []
    
    init(members: [String]) {
        self.members = members
    }
}

/// A table view controller that displays the timeline of a room.
///
/// This class subclasses `UIViewController` as `UITableViewController` adds some
/// extra keyboard handling magic that wasn't playing well with SwiftUI (as of iOS 16.1).
/// Also this TableViewController uses a **flipped tableview**
class TimelineTableViewController: UIViewController {
    private let coordinator: TimelineViewRepresentable.Coordinator
    private let tableView = UITableView(frame: .zero, style: .plain)
    
    var timelineItemsDictionary = OrderedDictionary<TimelineItemIdentifier.UniqueID, RoomTimelineItemViewState>() {
        didSet {
            guard canApplySnapshot else {
                hasPendingItems = true
                return
            }
            
            applySnapshot()
            
            if timelineItemsDictionary.isEmpty {
                paginatePublisher.send()
            }
        }
    }
    
    /// Whether or not it is safe to update the data source with the latest items.
    private var canApplySnapshot: Bool {
        if isLive {
            // Backward pagination jumps if items are inserted whilst actively dragging.
            !isDraggingScrollView
        } else {
            // Forward pagination breaks inertial scrolling when fixing the offset.
            !scrollViewIsScrolling
        }
    }
    
    /// There are pending items in `timelineItemsDictionary` that haven't been applied to the data source.
    private var hasPendingItems = false
    
    /// The scroll view is scrolling either directly with a drag or indirectly with inertia.
    private var scrollViewIsScrolling = false {
        didSet {
            if !scrollViewIsScrolling, hasPendingItems, !isLive {
                hasPendingItems = false
                applySnapshot()
            }
        }
    }
    
    /// The scroll view is being dragged by the user (doesn't include scrolling with inertia)
    private var isDraggingScrollView = false {
        didSet {
            if !isDraggingScrollView, hasPendingItems, isLive {
                hasPendingItems = false
                applySnapshot()
            }
        }
    }
    
    /// Whether or not the current timeline is live or built around an event ID.
    var isLive = true {
        didSet {
            // Update isScrolledToBottom when switching back to a live timeline.
            if isLive { scrollViewDidScroll(tableView) }
        }
    }
    
    /// The state of pagination (in both directions) of the current timeline.
    var paginationState: TimelinePaginationState = .initial {
        didSet {
            // Paginate again if the threshold hasn't been satisfied.
            paginatePublisher.send(())
        }
    }
    
    /// Whether the table view is about to load items from a new timeline or not.
    var isSwitchingTimelines = false

    /// Whether the timeline content is visible rather than covered by the emergency privacy placeholder.
    var isTimelineContentVisible = false {
        didSet {
            guard isTimelineContentVisible, !oldValue else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, isTimelineContentVisible else { return }
                tableView.layoutIfNeeded()
                resumeFocussedScrollIfNeeded()
                sendLastVisibleItemReadReceipt()
            }
        }
    }
    
    /// The focussed event if navigating to an event permalink within the room.
    var focussedEvent: TimelineState.FocussedEvent? {
        didSet {
            guard let focussedEvent else {
                cancelFocussedScrollRequest()
                return
            }
            guard focussedEvent.appearance != .hasAppeared else {
                if focussedScrollRequest?.eventID != focussedEvent.eventID {
                    cancelFocussedScrollRequest()
                }
                return
            }

            beginFocussedScrollRequest(eventID: focussedEvent.eventID, animated: focussedEvent.appearance == .animated)
        }
    }
    
    var hideTimelineMedia = false {
        didSet {
            guard let snapshot = dataSource?.snapshot() else { return }
            dataSource?.applySnapshotUsingReloadData(snapshot)
        }
    }
    
    /// Used to hold an observable object that the typing indicator can use
    let typingMembers = TypingMembersObservableObject(members: [])
    
    /// Updates the typing members but also updates table view items
    func setTypingMembers(_ members: [String]) {
        DispatchQueue.main.async {
            // Avoid `Publishing changes from within view update` warnings
            self.typingMembers.members = members
        }
    }
    
    @Binding private var isScrolledToBottom: Bool
    @Binding private var floatingDate: Date?
    
    /// A work item used to auto-hide the floating date badge after scrolling stops.
    private var floatingDateHideWorkItem: DispatchWorkItem?

    private var timelineItemsIDs: [TimelineItemIdentifier.UniqueID] {
        timelineItemsDictionary.keys.elements.reversed()
    }
    
    /// The table's diffable data source.
    private var dataSource: UITableViewDiffableDataSource<TimelineSection, TimelineItemIdentifier.UniqueID>?
    private var cancellables = Set<AnyCancellable>()

    /// A publisher used to throttle back pagination requests.
    ///
    /// Our view actions get wrapped in a `Task` so it is possible that a second call in
    /// quick succession can execute before ``paginationState`` acknowledges that
    /// pagination is in progress.
    private let paginatePublisher = PassthroughSubject<Void, Never>()
    
    /// A value to determine the scroll velocity threshold to detect a change in direction of the scroll view
    private let scrollVelocityThreshold: CGFloat = 50.0
    /// A publisher used to throttle scroll direction changes
    private let scrollDirectionPublisher = PassthroughSubject<ScrollDirection, Never>()
    /// Whether or not the view has been shown on screen yet.
    private var hasAppearedOnce = false
    /// Whether the timeline is actually visible on screen.
    private var isTimelineVisible = false

    struct FocussedScrollRequestState {
        struct Request {
            let eventID: String
            let animated: Bool
            let generation: Int
            var hasStarted = false
        }

        private(set) var generation = 0
        private(set) var request: Request?

        var isPending: Bool {
            request != nil
        }

        mutating func begin(eventID: String, animated: Bool) -> Int {
            generation += 1
            request = .init(eventID: eventID, animated: animated, generation: generation)
            return generation
        }

        mutating func markStarted(requestGeneration: Int) -> Bool {
            guard request?.generation == requestGeneration else { return false }

            request?.hasStarted = true
            return true
        }

        mutating func markForRetry(requestGeneration: Int) {
            guard request?.generation == requestGeneration else { return }

            request?.hasStarted = false
        }

        mutating func complete(requestGeneration: Int? = nil, visibleEventIDs: [String]) -> Bool {
            guard let request,
                  request.hasStarted,
                  requestGeneration.map({ $0 == request.generation }) ?? true,
                  visibleEventIDs.contains(request.eventID) else {
                return false
            }

            self.request = nil
            return true
        }

        mutating func cancel() {
            generation += 1
            request = nil
        }
    }

    private var focussedScrollRequestState = FocussedScrollRequestState()
    private var focussedScrollAnimationGeneration: Int?

    private var focussedScrollRequest: FocussedScrollRequestState.Request? {
        focussedScrollRequestState.request
    }
    
    /// Value that determines if the table view is flipped or not according to the VoiceOver status.
    private var scaleY: CGFloat {
        UIAccessibility.isVoiceOverRunning ? 1 : -1
    }
    
    init(coordinator: TimelineViewRepresentable.Coordinator,
         isScrolledToBottom: Binding<Bool>,
         floatingDate: Binding<Date?>,
         scrollToBottomPublisher: PassthroughSubject<Void, Never>,
         scrollToFirstItemForDatePublisher: PassthroughSubject<Void, Never>) {
        self.coordinator = coordinator
        _isScrolledToBottom = isScrolledToBottom
        _floatingDate = floatingDate
        
        super.init(nibName: nil, bundle: nil)
        
        tableView.register(TimelineItemCell.self, forCellReuseIdentifier: TimelineItemCell.reuseIdentifier)
        tableView.register(TimelineTypingIndicatorCell.self, forCellReuseIdentifier: TimelineTypingIndicatorCell.reuseIdentifier)
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .onDrag
        tableView.backgroundColor = .compound.bgCanvasDefault
        
        // The tableview should be flipped to display the newest items at the top
        // the only exception is VoiceOver, where we want to keep the latest item at the top as Android.
        tableView.transform = CGAffineTransform(scaleX: 1, y: scaleY)
        view.addSubview(tableView)
        
        // Prevents XCUITest from invoking the diffable dataSource's cellProvider
        // for each possible cell, causing layout issues
        tableView.accessibilityElementsHidden = ProcessInfo.shouldDisableTimelineAccessibility
        
        scrollToBottomPublisher
            .sink { [weak self] _ in
                self?.scrollToNewestItem(animated: true)
            }
            .store(in: &cancellables)
        
        scrollToFirstItemForDatePublisher
            .sink { [weak self] _ in
                self?.scrollToFirstItemForCurrentDate()
            }
            .store(in: &cancellables)
        
        paginatePublisher
            .collect(.byTime(DispatchQueue.main, 0.1))
            .sink { [weak self] _ in
                self?.paginateIfNeeded()
            }
            .store(in: &cancellables)
        
        scrollDirectionPublisher
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .sink { direction in
                coordinator.send(viewAction: .hasScrolled(direction: direction))
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.sendLastVisibleItemReadReceipt()
            }
            .store(in: &cancellables)
        
        // Observe voice over status changes to flip the table view accordingly
        NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                tableView.transform = CGAffineTransform(scaleX: 1, y: scaleY)
                tableView.reloadData()
            }
            .store(in: &cancellables)
        
        configureDataSource()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available.")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        guard !hasAppearedOnce else { return }
        tableView.contentOffset.y = -1
        hasAppearedOnce = true
        paginatePublisher.send()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        isTimelineVisible = true
        tableView.layoutIfNeeded()
        resumeFocussedScrollIfNeeded()
        sendLastVisibleItemReadReceipt()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        isTimelineVisible = false
        prepareFocussedScrollForRetryIfNeeded()
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        guard tableView.frame.size != view.frame.size else {
            return
        }
        
        tableView.frame = CGRect(origin: .zero, size: view.frame.size)
    }
    
    /// Configures a diffable data source for the timeline's table view.
    private func configureDataSource() {
        dataSource = .init(tableView: tableView) { [weak self] tableView, indexPath, id in
            switch id {
            case TimelineItemIdentifier.UniqueID(TimelineTypingIndicatorCell.reuseIdentifier):
                let cell = tableView.dequeueReusableCell(withIdentifier: TimelineTypingIndicatorCell.reuseIdentifier, for: indexPath)
                guard let self else {
                    return cell
                }
                
                cell.contentConfiguration = UIHostingConfiguration {
                    TypingIndicatorView(typingMembers: self.typingMembers)
                }
                .margins(.vertical, 0)
                .minSize(height: 0)
                .background(Color.clear)
                
                // Flipping the cell can create some issues with cell resizing, so flip the content View
                cell.contentView.transform = CGAffineTransform(scaleX: 1, y: scaleY)
                cell.accessibilityElements = [cell.contentView] // Ensure VoiceOver reads the content view only
                
                return cell
            default:
                let cell = tableView.dequeueReusableCell(withIdentifier: TimelineItemCell.reuseIdentifier, for: indexPath)
                guard let self, let cell = cell as? TimelineItemCell else { return cell }
                
                let viewState = timelineItemsDictionary[id]
                cell.item = viewState
                guard let viewState else {
                    return cell
                }
                
                cell.contentConfiguration = UIHostingConfiguration { [coordinator, hideTimelineMedia] in
                    RoomTimelineItemView(viewState: viewState)
                        .id(id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environmentObject(coordinator.context) // Attempted fix at a crash in TimelineItemContextMenu
                        .environment(\.timelineContext, coordinator.context)
                        .environment(\.shouldAutomaticallyLoadImages, !hideTimelineMedia)
                }
                .margins(.all, 0) // Margins are handled in the stylers
                .minSize(height: 1)
                .background(Color.clear)
                
                // Flipping the cell can create some issues with cell resizing, so flip the content View
                cell.contentView.transform = CGAffineTransform(scaleX: 1, y: scaleY)
                return cell
            }
        }
        
        // We only animate when there's a new last message, so its safe
        // to animate from the bottom (which is the top as we're flipped).
        dataSource?.defaultRowAnimation = (UIAccessibility.isReduceMotionEnabled ? .none : .top)
        tableView.delegate = self
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(accessibilityReduceMotionDidChange),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification,
                                               object: nil)
    }
    
    @objc private func accessibilityReduceMotionDidChange() {
        dataSource?.defaultRowAnimation = (UIAccessibility.isReduceMotionEnabled ? .none : .top)
    }
    
    /// Updates the table view with the latest items from the ``timelineItems`` array. After
    /// updating the data, the table will be scrolled to the bottom if it was visible otherwise
    /// the scroll position will be updated to maintain the position of the last visible item.
    private func applySnapshot() {
        guard let dataSource else { return }

        var snapshot = NSDiffableDataSourceSnapshot<TimelineSection, TimelineItemIdentifier.UniqueID>()
        
        // We don't want to display the typing notification in this timeline
        if coordinator.context.viewState.timelineKind != .pinned {
            snapshot.appendSections([.typingIndicator])
            snapshot.appendItems([TimelineItemIdentifier.UniqueID(TimelineTypingIndicatorCell.reuseIdentifier)])
        }
        snapshot.appendSections([.main])
        snapshot.appendItems(timelineItemsIDs)
        
        let currentSnapshot = dataSource.snapshot()
        
        let newestItemIdentifier = snapshot.mainItemIdentifiers.first
        let currentNewestItemIdentifier = currentSnapshot.mainItemIdentifiers.first
        let newestItemIDChanged = snapshot.numberOfMainItems > 0 && currentSnapshot.numberOfMainItems > 0 && newestItemIdentifier != currentNewestItemIdentifier
        let animated = TimelineSnapshotAnimationPolicy.shouldAnimate(isLive: isLive,
                                                                     isSwitchingTimelines: isSwitchingTimelines,
                                                                     newestItemIDChanged: newestItemIDChanged,
                                                                     currentItemIDs: currentSnapshot.mainItemIdentifiers,
                                                                     newItemIDs: snapshot.mainItemIdentifiers)
        
        let layout: Layout? = if !isLive, newestItemIDChanged {
            snapshotLayout()
        } else {
            nil
        }
        
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            guard let self else { return }
            tableView.layoutIfNeeded()
            completeFocussedScrollIfTargetVisible()
            prepareFocussedScrollForRetryIfTargetMissing()
            scheduleFocussedScrollIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.sendLastVisibleItemReadReceipt()
            }
        }
        
        if focussedScrollRequest != nil {
            scheduleFocussedScrollIfNeeded()
        } else if let layout {
            restoreLayout(layout)
        } else if isSwitchingTimelines {
            scrollToNewestItem(animated: false)
        }
        
        if isSwitchingTimelines {
            coordinator.send(viewAction: .hasSwitchedTimeline)
        }
    }
    
    /// Scrolls to the newest item in the timeline.
    private func scrollToNewestItem(animated: Bool) {
        guard !timelineItemsIDs.isEmpty else {
            return
        }
        tableView.scrollToRow(at: IndexPath(item: 0, section: 0), at: .top, animated: animated)
        scrollDirectionPublisher.send(.bottom)
    }

    /// Scrolls to the oldest item in the timeline.
    private func scrollToOldestItem(animated: Bool) {
        guard !timelineItemsIDs.isEmpty else {
            return
        }
        tableView.scrollToRow(at: IndexPath(item: timelineItemsIDs.count - 1, section: 1), at: .bottom, animated: animated)
        scrollDirectionPublisher.send(.top)
    }
    
    private func beginFocussedScrollRequest(eventID: String, animated: Bool) {
        _ = focussedScrollRequestState.begin(eventID: eventID, animated: animated)
        scheduleFocussedScrollIfNeeded()
    }

    private func cancelFocussedScrollRequest() {
        focussedScrollRequestState.cancel()
        focussedScrollAnimationGeneration = nil
    }

    private func scheduleFocussedScrollIfNeeded() {
        guard isTimelineVisible,
              isTimelineContentVisible,
              let focussedScrollRequest,
              !focussedScrollRequest.hasStarted else {
            return
        }
        let generation = focussedScrollRequest.generation

        DispatchQueue.main.async { [weak self] in // Fixes #2805
            self?.scrollToFocussedItem(requestGeneration: generation)
        }
    }

    /// Scrolls to the requested event if loaded, otherwise keeps the request pending for the next snapshot.
    private func scrollToFocussedItem(requestGeneration: Int) {
        guard isTimelineVisible,
              isTimelineContentVisible,
              let request = focussedScrollRequest,
              request.generation == requestGeneration,
              !request.hasStarted,
              let kvPair = timelineItemsDictionary.first(where: { $0.value.identifier.eventID == request.eventID }),
              let indexPath = dataSource?.indexPath(for: kvPair.key) else {
            return
        }

        guard focussedScrollRequestState.markStarted(requestGeneration: requestGeneration) else { return }
        if request.animated {
            focussedScrollAnimationGeneration = requestGeneration
        }

        // Scrolling to the middle created a small bump in the timeline. Using top, which is bottom
        // in the reversed timeline, helps with rendering full long messages and images.
        tableView.scrollToRow(at: indexPath, at: .top, animated: request.animated)
        coordinator.send(viewAction: .scrolledToFocussedItem)

        tableView.layoutIfNeeded()
        if !completeFocussedScrollIfTargetVisible(requestGeneration: requestGeneration), !request.animated {
            focussedScrollRequestState.markForRetry(requestGeneration: requestGeneration)
        }

        // Ensure VoiceOver focus happens after the scroll animation (if any).
        DispatchQueue.main.asyncAfter(deadline: .now() + (request.animated ? 0.5 : 0.0)) { [weak self] in
            guard let self else { return }
            if let cell = tableView.cellForRow(at: indexPath) {
                UIAccessibility.post(notification: .layoutChanged, argument: cell)
            }
        }
    }

    @discardableResult
    private func completeFocussedScrollIfTargetVisible(requestGeneration: Int? = nil) -> Bool {
        let generation = focussedScrollRequest?.generation
        let didComplete = focussedScrollRequestState.complete(requestGeneration: requestGeneration,
                                                              visibleEventIDs: visibleItemIdentifiers().compactMap(\.eventID))
        guard didComplete else {
            return false
        }

        if focussedScrollAnimationGeneration == generation {
            focussedScrollAnimationGeneration = nil
        }
        sendLastVisibleItemReadReceipt()
        return true
    }

    private func prepareFocussedScrollForRetryIfNeeded() {
        tableView.layoutIfNeeded()
        guard !completeFocussedScrollIfTargetVisible(),
              let request = focussedScrollRequest,
              request.hasStarted else {
            return
        }

        focussedScrollRequestState.markForRetry(requestGeneration: request.generation)
        if focussedScrollAnimationGeneration == request.generation {
            focussedScrollAnimationGeneration = nil
        }
    }

    private func resumeFocussedScrollIfNeeded() {
        prepareFocussedScrollForRetryIfNeeded()
        scheduleFocussedScrollIfNeeded()
    }

    private func prepareFocussedScrollForRetryIfTargetMissing() {
        guard let request = focussedScrollRequest,
              request.hasStarted,
              !timelineItemsDictionary.values.contains(where: { $0.identifier.eventID == request.eventID }) else {
            return
        }

        focussedScrollRequestState.markForRetry(requestGeneration: request.generation)
        if focussedScrollAnimationGeneration == request.generation {
            focussedScrollAnimationGeneration = nil
        }
    }
    
    /// Checks whether or not pagination is needed in either direction and requests one if so.
    ///
    /// **Note:** Prefer not to call this directly, instead using ``paginatePublisher`` to throttle requests.
    private func paginateIfNeeded() {
        guard !hasPendingItems else { return }
        
        if paginationState.backward == .idle,
           tableView.contentOffset.y > tableView.contentSize.height - tableView.visibleSize.height * 2.0 {
            coordinator.send(viewAction: .paginateBackwards)
        }
        if !isLive,
           paginationState.forward == .idle,
           tableView.contentOffset.y < tableView.visibleSize.height {
            coordinator.send(viewAction: .paginateForwards)
        }
    }
    
    private func sendLastVisibleItemReadReceipt() {
        // Find the last visible timeline item and send a read receipt for it
        let visibleItemIDs = visibleItemIdentifiers()
        guard let visibleItemID = Self.readReceiptItemIdentifier(in: visibleItemIDs,
                                                                 isTimelineVisible: isTimelineVisible,
                                                                 isTimelineContentVisible: isTimelineContentVisible,
                                                                 isFocussedScrollPending: focussedScrollRequestState.isPending) else { return }
        coordinator.send(viewAction: .sendReadReceiptIfNeeded(visibleItemID))
    }

    private func visibleItemIdentifiers() -> [TimelineItemIdentifier] {
        guard let visibleIndexPaths = tableView.indexPathsForVisibleRows else { return [] }

        // These are already in reverse order because the table view is flipped.
        return visibleIndexPaths.compactMap { indexPath in
            guard let visibleItemUniqueID = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            return timelineItemsDictionary[visibleItemUniqueID]?.identifier
        }
    }

    static func readReceiptItemIdentifier(in visibleItemIdentifiers: [TimelineItemIdentifier],
                                          isTimelineVisible: Bool,
                                          isTimelineContentVisible: Bool,
                                          isFocussedScrollPending: Bool) -> TimelineItemIdentifier? {
        guard isTimelineVisible, isTimelineContentVisible, !isFocussedScrollPending else { return nil }

        return visibleItemIdentifiers.first { $0.eventID != nil }
    }
}

enum TimelineSnapshotAnimationPolicy {
    static func shouldAnimate(isLive: Bool,
                              isSwitchingTimelines: Bool,
                              newestItemIDChanged: Bool,
                              currentItemIDs: [TimelineItemIdentifier.UniqueID],
                              newItemIDs: [TimelineItemIdentifier.UniqueID]) -> Bool {
        guard isLive, !isSwitchingTimelines else { return false }

        let removedItemIDs = Set(currentItemIDs).subtracting(newItemIDs)
        return newestItemIDChanged || !removedItemIDs.isEmpty
    }
}

// MARK: - UITableViewDelegate

extension TimelineTableViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        paginatePublisher.send(())
        completeFocussedScrollIfTargetVisible()
        
        // Dispatch to fix runtime warning about making changes during a view update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            let isScrolledToBottom = scrollView.contentOffset.y <= 0
            
            // Only update the binding on changes to avoid needlessly recomputing the hierarchy when scrolling.
            if self.isScrolledToBottom != isScrolledToBottom {
                self.isScrolledToBottom = isScrolledToBottom
            }
            
            if !isScrolledToBottom {
                updateFloatingDate()
            }
        }

        // We never want the table view to be fully at the bottom to allow the status bar tap to work properly
        if scrollView.contentOffset.y == 0 {
            scrollView.contentOffset.y = -1
        }
        
        let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView.superview).y
        if velocity > scrollVelocityThreshold {
            scrollDirectionPublisher.send(.top)
        } else if velocity < -scrollVelocityThreshold {
            scrollDirectionPublisher.send(.bottom)
        }
    }
    
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        scrollToOldestItem(animated: true)
        return false
    }
    
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelFocussedScrollRequest()
        isDraggingScrollView = true
        scrollViewIsScrolling = true
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        sendLastVisibleItemReadReceipt()
        
        isDraggingScrollView = false
        if !decelerate {
            scrollViewIsScrolling = false
        }
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        sendLastVisibleItemReadReceipt()
        scrollViewIsScrolling = false
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        tableView.layoutIfNeeded()
        let requestGeneration = focussedScrollAnimationGeneration ?? focussedScrollRequest?.generation
        focussedScrollAnimationGeneration = nil
        let didComplete = completeFocussedScrollIfTargetVisible(requestGeneration: requestGeneration)
        if !didComplete,
           let requestGeneration,
           focussedScrollRequest?.generation == requestGeneration {
            focussedScrollRequestState.markForRetry(requestGeneration: requestGeneration)
            scheduleFocussedScrollIfNeeded()
        }
        sendLastVisibleItemReadReceipt()
    }
}

// MARK: - Floating Date Badge

extension TimelineTableViewController {
    /// Computes the timestamp for the topmost visible timeline item
    /// and updates the floating date binding.
    func updateFloatingDate() {
        guard let date = newestVisibleDate() else {
            return
        }
        
        // Before updating it already schedule it's removal or the future.
        // The schedule needs to happen regardless of a value change
        // to extend the display duration of the floating date.
        scheduleFloatingDateHide()
        
        // Only update when the calendar day changes to avoid needless SwiftUI recomputation.
        if floatingDate.map({ !Calendar.current.isDate($0, inSameDayAs: date) }) ?? true {
            floatingDate = date
        }
    }
    
    /// Schedules the floating date badge to be hidden after a delay.
    func scheduleFloatingDateHide() {
        floatingDateHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.floatingDate = nil
        }
        floatingDateHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
    
    /// Scrolls to the first (oldest) item on the same calendar day as the current floating date.
    private func scrollToFirstItemForCurrentDate() {
        guard let floatingDate else { return }
        // timelineItemsDictionary is ordered oldest-first; the first match is the earliest item for that day.
        for uniqueID in timelineItemsDictionary.keys {
            if let timestamp = timelineItemsDictionary[uniqueID]?.timestamp,
               Calendar.current.isDate(timestamp, inSameDayAs: floatingDate),
               let indexPath = dataSource?.indexPath(for: uniqueID) {
                // The table view is flipped, so .bottom aligns the cell to the visual top.
                tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
                return
            }
        }
    }
    
    /// Returns the timestamp of the newest visible timeline item.
    ///
    /// The table view is flipped (unless VoiceOver is running), so the "newest"
    /// visible cell on screen is actually the *last* index path in `indexPathsForVisibleRows`
    /// when the table is flipped, or the *first* when it is not.
    private func newestVisibleDate() -> Date? {
        guard let visibleIndexPaths = tableView.indexPathsForVisibleRows,
              !visibleIndexPaths.isEmpty else {
            return nil
        }
        
        // In a flipped table view the last index path is the topmost item on screen;
        // when VoiceOver is active the table is not flipped so the first is topmost.
        let isFlipped = scaleY == -1
        let orderedPaths = isFlipped ? visibleIndexPaths.reversed() : visibleIndexPaths
        
        // Walk from topmost downward and return the timestamp of the first item that has one.
        for indexPath in orderedPaths {
            if let uniqueID = dataSource?.itemIdentifier(for: indexPath),
               let timestamp = timelineItemsDictionary[uniqueID]?.timestamp {
                return timestamp
            }
        }
        
        return nil
    }
}

// MARK: - Layout

extension TimelineTableViewController {
    /// The sections of the table view used in the diffable data source.
    enum TimelineSection {
        case main
        case typingIndicator
    }
    
    /// A representation of the table's layout based on a particular item.
    private struct Layout {
        let id: TimelineItemIdentifier
        let frame: CGRect
    }
    
    /// The current layout of the table, based on the newest timeline item.
    private func snapshotLayout() -> Layout? {
        guard let newestItemID = newestVisibleItemID(),
              let newestCellFrame = cellFrame(for: newestItemID.uniqueID) else {
            return nil
        }
        return Layout(id: newestItemID, frame: newestCellFrame)
    }
    
    /// Restores the timeline's layout from an old snapshot.
    private func restoreLayout(_ layout: Layout) {
        if let indexPath = dataSource?.indexPath(for: layout.id.uniqueID) {
            // Scroll the item into view.
            tableView.scrollToRow(at: indexPath, at: .top, animated: false)
            
            // Remove any unwanted offset that was added by scrollToRow.
            if let frame = cellFrame(for: layout.id.uniqueID) {
                let deltaY = frame.maxY - layout.frame.maxY
                if deltaY != 0 {
                    tableView.contentOffset.y -= deltaY
                }
            }
        }
    }
    
    /// Returns the frame of the cell for a particular timeline item.
    private func cellFrame(for uniqueID: TimelineItemIdentifier.UniqueID) -> CGRect? {
        guard let timelineCell = tableView.visibleCells.first(where: { ($0 as? TimelineItemCell)?.item?.identifier.uniqueID == uniqueID }) else {
            return nil
        }
        
        return tableView.convert(timelineCell.frame, to: tableView.superview)
    }
    
    /// The item ID of the newest visible item in the timeline.
    private func newestVisibleItemID() -> TimelineItemIdentifier? {
        guard let timelineCell = tableView.visibleCells.first(where: {
            guard let cell = $0 as? TimelineItemCell else { return false }
            return !(cell.item?.type is PaginationIndicatorRoomTimelineItem)
        }) else {
            return nil
        }
        return (timelineCell as? TimelineItemCell)?.item?.identifier
    }
}

private extension NSDiffableDataSourceSnapshot<TimelineTableViewController.TimelineSection, TimelineItemIdentifier.UniqueID> {
    var numberOfMainItems: Int {
        guard sectionIdentifiers.contains(.main) else { return 0 }
        return numberOfItems(inSection: .main)
    }
    
    var mainItemIdentifiers: [TimelineItemIdentifier.UniqueID] {
        guard sectionIdentifiers.contains(.main) else { return [] }
        return itemIdentifiers(inSection: .main)
    }
}
