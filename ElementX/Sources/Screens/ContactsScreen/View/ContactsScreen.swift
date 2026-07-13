//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ContactsScreen: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var context: ContactsScreenViewModel.Context

    var body: some View {
        content
            .compoundList()
            .navigationTitle("通讯录")
            .navigationBarTitleDisplayMode(.inline)
            .alert(item: $context.alertInfo)
            .task {
                context.send(viewAction: .task)
            }
            .refreshable {
                context.send(viewAction: .refresh)
                while context.viewState.isLoading, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                context.send(viewAction: .refresh)
            }
    }

    @ViewBuilder
    private var content: some View {
        if context.viewState.isInitialLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if context.viewState.contacts.isEmpty, context.viewState.hasLoadError {
            loadErrorView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if context.viewState.isEmpty {
            Text("暂无联系人")
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if context.viewState.isLoading {
                        ProgressView()
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("正在刷新通讯录")
                    } else if context.viewState.hasLoadError {
                        loadErrorView
                            .padding(.vertical, 12)
                    }

                    ForEach(context.viewState.contacts, id: \.userID) { contact in
                        ListRow(label: .avatar(title: displayTitle(for: contact),
                                               description: nil,
                                               icon: avatar(for: contact)),
                                details: .isWaiting(context.viewState.processingUserID == contact.userID),
                                kind: .button {
                                    context.send(viewAction: .selectContact(contact))
                                })
                                .disabled(context.viewState.processingUserID != nil)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
    }

    private var loadErrorView: some View {
        VStack(spacing: 12) {
            Text("通讯录加载失败，请稍后重试。")
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)

            Button("重试") {
                context.send(viewAction: .refresh)
            }
            .buttonStyle(.compound(.primary, size: .medium))
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func avatar(for contact: UserProfileProxy) -> some View {
        LoadableAvatarImage(url: contact.avatarURL,
                            name: contact.displayName,
                            contentID: contact.userID,
                            avatarSize: .user(on: .startChat),
                            mediaProvider: context.mediaProvider)
            .accessibilityHidden(true)
    }

    private func displayTitle(for contact: UserProfileProxy) -> String {
        guard let displayName = contact.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else {
            return contact.userID
                .trimmingPrefix("@")
                .split(separator: ":", maxSplits: 1)
                .first
                .map(String.init) ?? contact.userID
        }

        return displayName
    }
}

// MARK: - Previews

struct ContactsScreen_Previews: PreviewProvider, TestablePreview {
    static let clientProxy = ClientProxyMock(.init(userID: "@me:junchat.yyzs120.cn"))
    static let viewModel = ContactsScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                   contactsService: ContactsService(clientProxy: clientProxy),
                                                   userIndicatorController: UserIndicatorControllerMock())

    static var previews: some View {
        ElementNavigationStack {
            ContactsScreen(context: viewModel.context)
        }
    }
}
