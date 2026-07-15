//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct MessageForwardingScreen: View {
    @ObservedObject var context: MessageForwardingScreenViewModel.Context
    
    var body: some View {
        Form {
            Section {
                ForEach(context.viewState.rooms) { room in
                    MessageForwardingListRow(room: room,
                                             isSelected: context.viewState.selectedRoomID == room.id,
                                             context: context)
                        .disabled(context.viewState.isDestinationLocked || context.viewState.forwardingProgress?.isBusy == true)
                }
                // Replace these with ScrollView's `scrollPosition` when dropping iOS 16.
            } header: {
                emptyRectangle
                    .onAppear {
                        context.send(viewAction: .reachedTop)
                    }
            } footer: {
                emptyRectangle
                    .onAppear {
                        context.send(viewAction: .reachedBottom)
                    }
            }

            if let progress = context.viewState.forwardingProgress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if progress.isBusy {
                                ProgressView()
                            }
                            Text(progress.statusTitle)
                                .foregroundStyle(progress.showsFailure || progress.unknownCount > 0 ? Color.compound.textCriticalPrimary : Color.compound.textPrimary)
                        }

                        let resolvedCount = progress.queuedCount + progress.unknownCount
                        ProgressView(value: Double(resolvedCount), total: Double(progress.totalCount))
                            .accessibilityValue(UntranslatedL10n.screenMessageForwardingProgressAccessibilityValue(resolvedCount, progress.totalCount))
                    }
                }
            }
        }
        .compoundList()
        .navigationTitle(L10n.commonForwardMessage)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.actionCancel) {
                    context.send(viewAction: .cancel)
                }
                .disabled(context.viewState.forwardingProgress?.isCancelling == true)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(context.viewState.forwardingProgress?.sendButtonTitle ?? L10n.actionSend) {
                    context.send(viewAction: .send)
                }
                .disabled(!context.viewState.canSend)
            }
        }
        .searchController(query: $context.searchQuery, showsCancelButton: false)
        .compoundSearchField()
        .disableAutocorrection(true)
        .alert(UntranslatedL10n.screenMessageForwardingResolutionTitle,
               isPresented: $context.isUnknownOutcomeResolutionPresented) {
            Button(UntranslatedL10n.screenMessageForwardingContinueWithoutResending) {
                context.send(viewAction: .continueWithoutResending)
            }
            Button(UntranslatedL10n.screenMessageForwardingSendAgain, role: .destructive) {
                context.send(viewAction: .sendUnknownAgain)
            }
            Button(L10n.actionCancel, role: .cancel) {
                context.send(viewAction: .cancelUnknownOutcomeResolution)
            }
        } message: {
            Text(UntranslatedL10n.screenMessageForwardingResolutionMessage)
        }
    }
    
    /// The greedy size of Rectangle can create an issue with the navigation bar when the search is highlighted, so is best to use a fixed frame instead of hidden() or EmptyView()
    private var emptyRectangle: some View {
        Rectangle()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

private struct MessageForwardingListRow: View {
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    
    let room: MessageForwardingRoom
    let isSelected: Bool
    let context: MessageForwardingScreenViewModel.Context
    
    var body: some View {
        ListRow(label: .avatar(title: room.title,
                               description: room.description,
                               icon: avatar),
                kind: .selection(isSelected: isSelected) {
                    context.send(viewAction: .selectRoom(roomID: room.id))
                })
    }
    
    @ViewBuilder @MainActor
    var avatar: some View {
        if dynamicTypeSize < .accessibility3 {
            RoomAvatarImage(avatar: room.avatar,
                            avatarSize: .room(on: .messageForwarding),
                            mediaProvider: context.mediaProvider)
                .dynamicTypeSize(dynamicTypeSize < .accessibility1 ? dynamicTypeSize : .accessibility1)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Previews

struct MessageForwardingScreen_Previews: PreviewProvider, TestablePreview {
    static let initialViewModel = makeViewModel()
    static let queueingViewModel = makeViewModel(selectedRoomID: "2",
                                                 progress: .init(totalCount: 3, queuedCount: 1, failedCount: 1, isQueueing: true))
    static let partiallyFailedViewModel = makeViewModel(selectedRoomID: "2",
                                                        progress: .init(totalCount: 3, queuedCount: 2, failedCount: 1, isQueueing: false))
    static let fullyFailedViewModel = makeViewModel(selectedRoomID: "2",
                                                    progress: .init(totalCount: 3, queuedCount: 0, failedCount: 3, isQueueing: false))
    static let unknownOutcomeViewModel = makeViewModel(selectedRoomID: "2",
                                                       progress: .init(totalCount: 3, queuedCount: 1, failedCount: 0, unknownCount: 2, isQueueing: false))

    static var previews: some View {
        ElementNavigationStack {
            MessageForwardingScreen(context: initialViewModel.context)
        }
        .previewDisplayName("Initial")

        ElementNavigationStack {
            MessageForwardingScreen(context: queueingViewModel.context)
        }
        .previewDisplayName("Queueing with an earlier failure")

        ElementNavigationStack {
            MessageForwardingScreen(context: partiallyFailedViewModel.context)
        }
        .previewDisplayName("Partially failed and locked")

        ElementNavigationStack {
            MessageForwardingScreen(context: fullyFailedViewModel.context)
        }
        .previewDisplayName("Fully failed and unlocked")

        ElementNavigationStack {
            MessageForwardingScreen(context: unknownOutcomeViewModel.context)
        }
        .previewDisplayName("Unknown outcome")
    }

    static func makeViewModel(selectedRoomID: String? = nil,
                              progress: MessageForwardingProgress? = nil) -> MessageForwardingScreenViewModel {
        let summaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let viewModel = MessageForwardingScreenViewModel(forwardingBatch: .init(firstItem: .init(id: .randomEvent,
                                                                                                 roomID: "",
                                                                                                 content: .init(noHandle: .init()))),
                                                         userSession: UserSessionMock(.init()),
                                                         roomSummaryProvider: summaryProvider,
                                                         userIndicatorController: UserIndicatorControllerMock())
        viewModel.state.selectedRoomID = selectedRoomID
        viewModel.state.forwardingProgress = progress
        return viewModel
    }
}
