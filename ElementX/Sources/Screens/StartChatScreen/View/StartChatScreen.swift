//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct StartChatScreen: View {
    @ObservedObject var context: StartChatScreenViewModel.Context

    var body: some View {
        Form {
            if !context.viewState.isSearching {
                mainContent
            } else {
                searchContent
            }
        }
        .compoundList()
        .track(screen: .StartChat)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(L10n.actionStartChat)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .searchController(query: $context.searchQuery,
                          placeholder: L10n.commonSearchForSomeone,
                          showsCancelButton: false,
                          disablesInteractiveDismiss: true)
        .compoundSearchField()
        .alert(item: $context.alertInfo)
        .sheet(item: $context.selectedUserToInvite) { userToInvite in
            SendInviteConfirmationView(userToInvite: userToInvite,
                                       mediaProvider: context.mediaProvider) {
                context.send(viewAction: .createDM(user: userToInvite.user))
            }
        }
    }

    // MARK: - Private

    /// The content shown in the form when the search query is empty.
    @ViewBuilder
    private var mainContent: some View {
        createGroupChatSection
        usersSection
    }

    /// The content shown in the form when a search query has been entered.
    @ViewBuilder
    private var searchContent: some View {
        if context.viewState.hasEmptySearchResults {
            noResultsContent
        } else {
            usersSection
        }
    }

    @ViewBuilder
    private var createGroupChatSection: some View {
        if context.viewState.shouldShowCreateGroupChatEntry {
            Section {
                ListRow(label: .default(title: "创建群聊",
                                        description: "从通讯录选择多人开始聊天。",
                                        icon: Image(systemName: "person.2.fill")),
                        kind: .navigationLink {
                            context.send(viewAction: .createRoom)
                        })
            }
        } else {
            Section.empty
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        if !context.viewState.usersSection.users.isEmpty {
            Section {
                ForEach(context.viewState.usersSection.users, id: \.userID) { user in
                    UserProfileListRow(user: user,
                                       membership: nil,
                                       mediaProvider: context.mediaProvider,
                                       kind: .button {
                                           context.send(viewAction: .selectUser(user))
                                       })
                }
            } header: {
                if let title = context.viewState.usersSection.title {
                    Text(title)
                        .compoundListSectionHeader()
                }
            }
        } else {
            Section.empty
        }
    }

    private var noResultsContent: some View {
        Text(L10n.commonNoResults)
            .font(.compound.bodyLG)
            .foregroundColor(.compound.textSecondary)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier(A11yIdentifiers.startChatScreen.searchNoResults)
    }

    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.actionCancel) {
                context.send(viewAction: .close)
            }
            .accessibilityIdentifier(A11yIdentifiers.startChatScreen.closeStartChat)
        }
    }
}

// MARK: - Previews

struct StartChatScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = {
        let appSettings = AppSettings()
        appSettings.publicSearchEnabled = true
        let userSession = UserSessionMock(.init(clientProxy: ClientProxyMock(.init(userID: "@userid:example.com"))))
        let userDiscoveryService = UserDiscoveryServiceMock()
        userDiscoveryService.searchProfilesWithReturnValue = .success([.mockAlice])
        return StartChatScreenViewModel(userSession: userSession,
                                        analytics: ServiceLocator.shared.analytics,
                                        userIndicatorController: UserIndicatorControllerMock(),
                                        userDiscoveryService: userDiscoveryService,
                                        appSettings: appSettings)
    }()

    static var previews: some View {
        ElementNavigationStack {
            StartChatScreen(context: viewModel.context)
        }
    }
}
