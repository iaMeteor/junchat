//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SwiftUI
import WysiwygComposer

struct RoomScreen: View {
    @ObservedObject private var context: RoomScreenViewModelType.Context
    @ObservedObject private var timelineContext: TimelineViewModelType.Context
    let composerToolbar: ComposerToolbar
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @State private var isMessageRedactionConfirmationPresented = false
    @State private var showPrivacyModeBanner = false

    init(context: RoomScreenViewModelType.Context,
         timelineContext: TimelineViewModelType.Context,
         composerToolbar: ComposerToolbar) {
        self.context = context
        self.timelineContext = timelineContext
        self.composerToolbar = composerToolbar
    }

    var body: some View {
        TimelineView(timelineContext: timelineContext)
            .overlay(alignment: .bottomTrailing) {
                TimelineScrollToBottomButton(isVisible: isAtBottomAndLive,
                                             isInteractionLocked: isMessageSelectionActive) {
                    timelineContext.send(viewAction: .scrollToBottom)
                }
                .accessibilityIdentifier(A11yIdentifiers.roomScreen.scrollToBottom)
            }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .topBanners([
                TopBannerLayer(verticalBanners: [
                    TopBannerItem(activeCallJoinBanner.disabled(isMessageSelectionActive), isVisible: context.viewState.shouldShowActiveCallInvitation && !isVoiceOverEnabled),
                    TopBannerItem(privacyModeBanner, isVisible: shouldShowPrivacyModeBanner && !isVoiceOverEnabled),
                    TopBannerItem(pinnedItemsBanner.disabled(isMessageSelectionActive), isVisible: context.viewState.shouldShowPinnedEventsBanner && !isVoiceOverEnabled),
                    TopBannerItem(liveLocationBanner.disabled(isMessageSelectionActive), isVisible: context.viewState.isSharingLiveLocation && !isVoiceOverEnabled)
                ]),
                // This can overlay on top of the stacked banners
                TopBannerLayer(knockRequestsBanner.disabled(isMessageSelectionActive), isVisible: context.viewState.shouldSeeKnockRequests)
            ], footer: dateBadge)
            .safeAreaInset(edge: .top) {
                // When VoiceOver is enabled, the table view isn't reversed and the scroll gestures
                // don't trigger meaning the banner never hides itself and so the .overlay layout
                // above permanently obscures the top of the timeline. So whenever VoiceOver is
                // enabled we use a safe area inset to vertically stack it above the timeline.
                if context.viewState.shouldShowActiveCallInvitation || shouldShowPrivacyModeBanner || context.viewState.shouldShowPinnedEventsBanner || context.viewState.isSharingLiveLocation, isVoiceOverEnabled {
                    VStack(spacing: 0) {
                        if context.viewState.shouldShowActiveCallInvitation {
                            activeCallJoinBanner.disabled(isMessageSelectionActive)
                        }
                        if shouldShowPrivacyModeBanner {
                            privacyModeBanner
                        }
                        if context.viewState.shouldShowPinnedEventsBanner {
                            pinnedItemsBanner.disabled(isMessageSelectionActive)
                        }
                        if context.viewState.isSharingLiveLocation {
                            liveLocationBanner.disabled(isMessageSelectionActive)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    RoomScreenFooterView(details: context.viewState.footerDetails,
                                         mediaProvider: context.mediaProvider) { action in
                        context.send(viewAction: .footerViewAction(action))
                    }
                    .disabled(isMessageSelectionActive)

                    if timelineContext.viewState.messageSelectionState.isActive {
                        messageSelectionToolbar
                            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
                    } else {
                        composer
                            .padding(.top, 8)
                            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
                            .environmentObject(timelineContext)
                            .environment(\.timelineContext, timelineContext)
                            // Make sure the reply header honours the hideTimelineMedia setting too.
                            .environment(\.shouldAutomaticallyLoadImages, !timelineContext.viewState.hideTimelineMedia)
                    }
                }
            }
            .toolbarRole(RoomHeaderView.toolbarRole)
            .navigationTitle(L10n.screenRoomTitle) // Hidden but used for back button text.
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isMessageSelectionActive)
            .toolbar { toolbar }
            .toolbarBackground(.visible, for: .navigationBar) // Fix the toolbar's background.
            .overlay { loadingIndicator }
            .alert(UntranslatedL10n.screenRoomMessageSelectionDeleteConfirmationTitle, isPresented: $isMessageRedactionConfirmationPresented) {
                Button(L10n.actionCancel, role: .cancel) { }
                Button(L10n.actionDelete, role: .destructive) {
                    timelineContext.send(viewAction: .confirmMessageRedaction)
                }
            } message: {
                Text(UntranslatedL10n.screenRoomMessageSelectionDeleteConfirmation(timelineContext.viewState.messageSelectionState.selectedCount))
            }
            .alert(item: $context.alertInfo)
            .timelineMediaPreview(viewModel: $context.mediaPreviewViewModel)
            .track(screen: .Room)
            .sentryTrace("\(Self.self)")
            .task(id: context.viewState.isPrivacyModeEnabled) {
                if context.viewState.isPrivacyModeEnabled {
                    showPrivacyModeBanner = true
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled {
                        showPrivacyModeBanner = false
                    }
                } else {
                    showPrivacyModeBanner = false
                }
            }
    }

    private var liveLocationBanner: some View {
        LiveLocationSharingBannerView {
            context.send(viewAction: .tappedOpenLiveLocation)
        } onStop: {
            context.send(viewAction: .tappedStopLiveLocation)
        }
    }

    private var activeCallJoinBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: context.viewState.activeRoomCallIntent == .audio ? "phone.fill" : "video.fill")
                .font(.compound.headingSMSemibold)
                .foregroundStyle(.compound.iconAccentPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text("群聊正在通话")
                    .font(.compound.bodyMDSemibold)
                    .foregroundStyle(.compound.textPrimary)

                Text(context.viewState.activeRoomCallIntent == .audio ? "语音通话进行中" : "视频通话进行中")
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textSecondary)
            }

            Spacer(minLength: 0)

            Button {
                let shouldJoinAsVoice = RoomCallControlsToolbar.shouldJoinAsVoice(isDirectOneToOneRoom: context.viewState.isDirectOneToOneRoom,
                                                                                  activeCallIntent: context.viewState.activeRoomCallIntent)
                context.send(viewAction: .displayCall(isVoiceCall: shouldJoinAsVoice))
            } label: {
                Text("加入")
            }
            .buttonStyle(.compound(.primary, size: .small))

            Button {
                context.send(viewAction: .declineCallInvitation)
            } label: {
                Image(systemName: "xmark")
                    .font(.compound.bodyMDSemibold)
                    .foregroundStyle(.compound.iconSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("忽略通话提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.compound.bgCanvasDefault)
    }

    private var privacyModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.compound.bodyMDSemibold)

            Text("下面的对话是隐私模式，内容会在被阅读 3 分钟后自动销毁")
                .font(.compound.bodySM)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .foregroundStyle(.compound.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.compound.bgSubtlePrimary)
    }

    private var pinnedItemsBanner: some View {
        PinnedItemsBannerView(state: context.viewState.pinnedEventsBannerState,
                              onMainButtonTap: { context.send(viewAction: .tappedPinnedEventsBanner) },
                              onViewAllButtonTap: { context.send(viewAction: .viewAllPins) })
    }

    private var knockRequestsBanner: some View {
        KnockRequestsBannerView(requests: context.viewState.displayedKnockRequests,
                                onDismiss: dismissKnockRequestsBanner,
                                onAccept: context.viewState.canAcceptKnocks ? acceptKnockRequest : nil,
                                onViewAll: onViewAllKnockRequests,
                                mediaProvider: context.mediaProvider)
            .padding(.top, 16)
    }

    @ViewBuilder
    private var dateBadge: some View {
        if !isVoiceOverEnabled {
            FloatingDateBadge(dateText: timelineContext.floatingDate?.formattedDateSeparator()) {
                timelineContext.send(viewAction: .scrollToFirstItemForCurrentDate)
            }
        }
    }

    private func dismissKnockRequestsBanner() {
        context.send(viewAction: .dismissKnockRequests)
    }

    private func acceptKnockRequest(eventID: String) {
        context.send(viewAction: .acceptKnock(eventID: eventID))
    }

    private func onViewAllKnockRequests() {
        context.send(viewAction: .viewKnockRequests)
    }

    private var isAtBottomAndLive: Bool {
        timelineContext.isScrolledToBottom && timelineContext.viewState.timelineState.isLive
    }

    private var isMessageSelectionActive: Bool {
        timelineContext.viewState.messageSelectionState.isActive
    }

    private var shouldShowPrivacyModeBanner: Bool {
        context.viewState.isPrivacyModeEnabled && showPrivacyModeBanner
    }

    private var messageSelectionToolbar: some View {
        HStack(spacing: 12) {
            Text(UntranslatedL10n.screenRoomMessageSelectionSelectedCount(timelineContext.viewState.messageSelectionState.selectedCount))
                .font(.compound.bodyMDSemibold)
                .foregroundStyle(.compound.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(L10n.actionCancel) {
                timelineContext.send(viewAction: .cancelMessageSelection)
            }
            .buttonStyle(.compound(.tertiary, size: .medium))

            Button(L10n.actionForward) {
                timelineContext.send(viewAction: .forwardMessageSelection)
            }
            .buttonStyle(.compound(.tertiary, size: .medium))
            .disabled(!timelineContext.viewState.messageSelectionState.canForwardSelectedMessages)

            Button(L10n.actionDelete, role: .destructive) {
                isMessageRedactionConfirmationPresented = true
            }
            .buttonStyle(.compound(.tertiary, size: .medium))
            .disabled(!timelineContext.viewState.messageSelectionState.canRedactSelectedMessages)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var composer: some View {
        if context.viewState.hasSuccessor {
            tombstonedDialogue
        } else if context.viewState.canSendMessage, !ProcessInfo.isRunningAccessibilityTests {
            // We are not sure why but when wrapped in the room screen the composer toolbar breaks the accessibility tests
            composerToolbar
        } else {
            ComposerDisabledView()
        }
    }

    private var tombstonedDialogue: some View {
        VStack(spacing: 16) {
            Text(L10n.screenRoomTimelineTombstonedRoomMessage)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textPrimary)

            Button {
                context.send(viewAction: .displaySuccessorRoom)
            } label: {
                Text(L10n.screenRoomTimelineTombstonedRoomAction)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.primary, size: .medium))
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .highlight(gradient: .compound.info, borderColor: .compound.borderInfoSubtle)
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if timelineContext.viewState.showLoading {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.compound.textPrimary)
                .padding(16)
                .background(.ultraThickMaterial)
                .cornerRadius(8)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // .principal + .primaryAction works better than .navigation leading + trailing
        // as the latter disables interaction in the action button for rooms with long names
        ToolbarItem(placement: .principal) {
            RoomHeaderView(roomName: context.viewState.roomTitle,
                           roomAvatar: context.viewState.roomAvatar,
                           dmRecipientVerificationState: context.viewState.dmRecipientVerificationState,
                           roomHistorySharingState: context.viewState.roomHistorySharingState,
                           mediaProvider: context.mediaProvider) {
                context.send(viewAction: .displayRoomDetails)
            }
            .disabled(isMessageSelectionActive)
        }

        if !ProcessInfo.processInfo.isiOSAppOnMac {
            if context.viewState.shouldShowCallButton {
                RoomCallControlsToolbar(viewState: context.viewState,
                                        isDisabled: isMessageSelectionActive) { isVoiceCall in
                    context.send(viewAction: .displayCall(isVoiceCall: isVoiceCall))
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    context.send(viewAction: .togglePrivacyMode)
                } label: {
                    Image(systemName: context.viewState.isPrivacyModeEnabled ? "timer.circle.fill" : "timer")
                        .foregroundColor(context.viewState.isPrivacyModeEnabled ? .compound.iconAccentPrimary : .compound.iconPrimary)
                }
                .accessibilityLabel(context.viewState.isPrivacyModeEnabled ? "关闭隐私模式" : "开启隐私模式")
                .disabled(isMessageSelectionActive)
            }
        }

        if context.viewState.roomThreadListEnabled {
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    context.send(viewAction: .displayThreadList)
                } label: {
                    CompoundIcon(\.threads)
                }
                .disabled(isMessageSelectionActive)
            }
        }
    }
}

// MARK: - Previews

struct RoomScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModels = makeViewModels()
    static let readOnlyViewModels = makeViewModels(canSendMessage: false)
    static let tombstonedViewModels = makeViewModels(hasSuccessor: true)
    static let composerViewModel = ComposerToolbarViewModel.mock()

    static var previews: some View {
        ElementNavigationStack {
            RoomScreen(context: viewModels.room.context,
                       timelineContext: viewModels.timeline.context,
                       composerToolbar: ComposerToolbar(context: composerViewModel.context))
        }
        .previewDisplayName("Normal")

        ElementNavigationStack {
            RoomScreen(context: readOnlyViewModels.room.context,
                       timelineContext: readOnlyViewModels.timeline.context,
                       composerToolbar: ComposerToolbar(context: composerViewModel.context))
        }
        .previewDisplayName("Read-only")
        .snapshotPreferences(expect: readOnlyViewModels.room.context.$viewState.map { !$0.canSendMessage })

        ElementNavigationStack {
            RoomScreen(context: tombstonedViewModels.room.context,
                       timelineContext: tombstonedViewModels.timeline.context,
                       composerToolbar: ComposerToolbar(context: composerViewModel.context))
        }
        .previewDisplayName("Tombstoned")
        .snapshotPreferences(expect: tombstonedViewModels.room.context.$viewState.map(\.hasSuccessor))
    }

    static func makeViewModels(canSendMessage: Bool = true,
                               hasSuccessor: Bool = false,
                               selectedMessageID: TimelineItemIdentifier.EventOrTransactionID? = nil) -> ViewModels {
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "stable_id",
                                                      name: "Preview room",
                                                      hasOngoingCall: true,
                                                      successor: hasSuccessor ? .init(roomId: "!successor:example.org", reason: nil) : nil,
                                                      powerLevelsConfiguration: .init(canUserSendMessage: canSendMessage)))
        let appSettings: AppSettings = ServiceLocator.shared.settings
        appSettings.linkPreviewsEnabled = false
        let roomViewModel = RoomScreenViewModel.mock(roomProxyMock: roomProxyMock)
        let timelineViewModel = TimelineViewModel(roomProxy: roomProxyMock,
                                                  timelineController: MockTimelineController(),
                                                  userSession: UserSessionMock(.init()),
                                                  mediaPlayerProvider: MediaPlayerProviderMock(),
                                                  userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                  appMediator: AppMediatorMock.default,
                                                  appSettings: appSettings,
                                                  analyticsService: ServiceLocator.shared.analytics,
                                                  emojiProvider: EmojiProvider(appSettings: appSettings),
                                                  linkMetadataProvider: RoomScreenPreviewLinkMetadataProvider(),
                                                  timelineControllerFactory: TimelineControllerFactoryMock(.init()))
        if let selectedMessageID {
            timelineViewModel.state.messageSelectionState = .init(selectedIDs: [selectedMessageID])
        }

        return .init(room: roomViewModel, timeline: timelineViewModel)
    }

    struct ViewModels {
        let room: RoomScreenViewModelProtocol
        let timeline: TimelineViewModelProtocol
    }
}

struct RoomMessageSelectionScreen_Previews: PreviewProvider, TestablePreview {
    private static let selectedEventID = "RoomTimelineItemFixtures.default.6"
    static let viewModels = RoomScreen_Previews.makeViewModels(selectedMessageID: .eventID(selectedEventID))
    static let composerViewModel = ComposerToolbarViewModel.mock()

    static var previews: some View {
        ElementNavigationStack {
            RoomScreen(context: viewModels.room.context,
                       timelineContext: viewModels.timeline.context,
                       composerToolbar: ComposerToolbar(context: composerViewModel.context))
        }
        .previewDisplayName("Selecting messages")
        .snapshotPreferences(expect: viewModels.room.context.$viewState
            .combineLatest(viewModels.timeline.context.$viewState)
            .map { roomState, timelineState in
                roomState.roomTitle == "Preview room" &&
                    timelineState.messageSelectionState.selectedCount == 1 &&
                    timelineState.timelineState.hasLoadedItem(with: selectedEventID)
            })
    }
}

private final class RoomScreenPreviewLinkMetadataProvider: LinkMetadataProviderProtocol {
    let metadataItems = [URL: LinkMetadataProviderItem]()

    func fetchMetadataFor(url: URL) async -> Result<LinkMetadataProviderItem, Error> {
        .failure(URLError(.notConnectedToInternet))
    }
}
