//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AudioToolbox
import AVFoundation
import Compound
import SFSafeSymbols
import SwiftUI

struct SettingsScreen: View {
    let context: SettingsScreenViewModel.Context

    private var shouldHideManageAccountSection: Bool {
        context.viewState.accountProfileURL == nil &&
            !context.viewState.showBlockedUsers &&
            !context.viewState.showLinkNewDeviceButton
    }

    private var appVersionText: String {
        let version = Bundle.app.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.app.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            userSection

            if !shouldHideManageAccountSection {
                manageAccountSection
            }

            manageMyAppSection

            soundSection

            generalSection

            signOutSection

            if context.viewState.showDeveloperOptions {
                developerOptionsSection
            }
        }
        .compoundList()
        .navigationTitle(L10n.commonSettings)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(ProcessInfo.processInfo.isiOSAppOnMac ? .hidden : .automatic, for: .navigationBar)
        .toolbar { toolbar }
    }

    private var userSection: some View {
        Section {
            ListRow(kind: .custom {
                Button {
                    context.send(viewAction: .userDetails)
                } label: {
                    HStack(spacing: 12) {
                        LoadableAvatarImage(url: context.viewState.userAvatarURL,
                                            name: context.viewState.userDisplayName,
                                            contentID: context.viewState.userID,
                                            avatarSize: .user(on: .settings),
                                            mediaProvider: context.mediaProvider)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.viewState.userDisplayName ?? "")
                                .font(.compound.headingMD)
                                .foregroundColor(.compound.textPrimary)
                        }

                        Spacer()

                        ListRowAccessory.navigationLink
                    }
                    .padding(.horizontal, ListRowPadding.horizontal)
                    .padding(.vertical, 8)
                }
            })
        }
    }

    private var manageMyAppSection: some View {
        Section {
            let entertainmentTabBinding = Binding(get: {
                context.viewState.showEntertainmentTab
            }, set: { newValue in
                context.send(viewAction: .updateShowEntertainmentTab(newValue))
            })

            ListRow(label: .default(title: "娱乐 Tab",
                                    description: "开启后，底部会显示俄罗斯方块小游戏入口。",
                                    icon: Image(systemName: "gamecontroller")),
                    kind: .toggle(entertainmentTabBinding))

            ListRow(label: .default(title: "君聊支持中心",
                                    description: "查看使用帮助、管理员联系方式和隐私说明。",
                                    icon: Image(systemName: "lifepreserver")),
                    kind: .navigationLink {
                        context.send(viewAction: .junchatSupport)
                    })

            ListRow(label: .default(title: "修改登录密码",
                                    description: "使用原密码设置新的登录密码。",
                                    icon: Image(systemName: "key.fill")),
                    kind: .navigationLink {
                        context.send(viewAction: .changePassword)
                    })

            let contactsDirectoryVisibilityBinding = Binding(get: {
                context.viewState.hideFromContactsDirectory
            }, set: { newValue in
                context.send(viewAction: .updateHideFromContactsDirectory(newValue))
            })

            ListRow(label: .default(title: "不显示在他人通讯录",
                                    description: "开启后，其他人查看公司通讯录时不会看到你的账号。",
                                    icon: Image(systemName: "person.crop.circle.badge.xmark")),
                    details: .isWaiting(context.viewState.isWaitingContactsDirectoryVisibility),
                    kind: .toggle(contactsDirectoryVisibilityBinding))
                .disabled(context.viewState.isWaitingContactsDirectoryVisibility)

            ListRow(label: .default(title: L10n.screenNotificationSettingsTitle,
                                    icon: \.notifications),
                    kind: .navigationLink {
                        context.send(viewAction: .notifications)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.notifications)

            ListRow(label: .default(title: L10n.commonScreenLock,
                                    icon: \.lock),
                    kind: .navigationLink {
                        context.send(viewAction: .appLock)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.screenLock)

            switch context.viewState.securitySectionMode {
            case .secureBackup:
                ListRow(label: .default(title: L10n.commonEncryption,
                                        icon: \.key),
                        details: context.viewState.showSecuritySectionBadge ? .icon(securitySectionBadge) : nil,
                        kind: .navigationLink { context.send(viewAction: .secureBackup) })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.secureBackup)
            default:
                EmptyView()
            }
        }
    }

    private var soundSection: some View {
        Section {
            ListRow(label: .default(title: "消息铃声",
                                    description: context.viewState.selectedMessageNotificationSound.title,
                                    icon: Image(systemName: context.viewState.selectedMessageNotificationSound.systemImageName)),
                    kind: .navigationLink {
                        context.send(viewAction: .messageNotificationSoundSettings)
                    })

            ListRow(label: .default(title: "来电铃声",
                                    description: context.viewState.selectedCallRingtone.title,
                                    icon: Image(systemName: context.viewState.selectedCallRingtone.systemImageName)),
                    kind: .navigationLink {
                        context.send(viewAction: .callRingtoneSettings)
                    })
        }
    }

    private var manageAccountSection: some View {
        Section {
            if let url = context.viewState.accountProfileURL {
                ListRow(label: .default(title: L10n.actionManageAccountAndDevices,
                                        icon: \.userProfile),
                        kind: .button {
                            context.send(viewAction: .manageAccount(url: url))
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.account)
            }

            if context.viewState.showLinkNewDeviceButton {
                ListRow(label: .default(title: L10n.commonLinkNewDevice,
                                        icon: \.devices),
                        kind: .navigationLink {
                            context.send(viewAction: .linkNewDevice)
                        })
            }

            if context.viewState.showBlockedUsers {
                ListRow(label: .default(title: L10n.commonBlockedUsers,
                                        icon: \.block),
                        kind: .navigationLink {
                            context.send(viewAction: .blockedUsers)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.blockedUsers)
            }
        }
    }

    private var generalSection: some View {
        Section {
            ListRow(label: .default(title: L10n.commonAdvancedSettings,
                                    icon: \.settings),
                    kind: .navigationLink {
                        context.send(viewAction: .advancedSettings)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.advancedSettings)

            ListRow(label: .default(title: L10n.screenAdvancedSettingsLabs,
                                    icon: \.labs),
                    kind: .navigationLink {
                        context.send(viewAction: .labs)
                    })

            ListRow(label: .default(title: L10n.commonAbout,
                                    icon: \.info),
                    kind: .navigationLink {
                        context.send(viewAction: .about)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.about)

            ListRow(label: .default(title: "当前版本",
                                    description: appVersionText,
                                    icon: \.info),
                    kind: .label)

            if context.viewState.isBugReportServiceEnabled {
                ListRow(label: .default(title: L10n.commonReportAProblem,
                                        icon: \.chatProblem),
                        kind: .navigationLink {
                            context.send(viewAction: .reportBug)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.reportBug)
            }

            if context.viewState.showAnalyticsSettings {
                ListRow(label: .default(title: L10n.commonAnalytics,
                                        icon: \.chart),
                        kind: .navigationLink {
                            context.send(viewAction: .analytics)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.analytics)
            }
        }
    }

    private var signOutSection: some View {
        Section {
            ListRow(label: .action(title: L10n.screenSignoutPreferenceItem,
                                   icon: \.close,
                                   role: .destructive),
                    kind: .button {
                        context.send(viewAction: .logout)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.logout)

            if context.viewState.showAccountDeactivation {
                ListRow(label: .action(title: L10n.actionDeleteAccount,
                                       icon: \.delete,
                                       role: .destructive),
                        kind: .navigationLink {
                            context.send(viewAction: .deactivateAccount)
                        })
            }
        }
    }

    private var developerOptionsSection: some View {
        Section {
            ListRow(label: .default(title: L10n.commonDeveloperOptions,
                                    icon: \.code),
                    kind: .navigationLink {
                        context.send(viewAction: .developerOptions)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.developerOptions)
        }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ToolbarButton(role: .close) { context.send(viewAction: .close) }
                .accessibilityIdentifier(A11yIdentifiers.settingsScreen.done)
        }
    }

    @ViewBuilder
    private var securitySectionBadge: some View {
        if context.viewState.showSecuritySectionBadge {
            BadgeView(size: 10)
        }
    }
}

struct MessageNotificationSoundSettingsScreen: View {
    let context: SettingsScreenViewModel.Context
    @State private var soundPreviewPlayer: AVAudioPlayer?

    var body: some View {
        Form {
            Section {
                ForEach(JunchatMessageNotificationSound.allCases) { sound in
                    messageSoundRow(sound)
                }
            } footer: {
                Text("选择后会作为当前消息提示音。你可以先试听，再切换到喜欢的声音。")
                    .compoundListSectionFooter()
            }
        }
        .compoundList()
        .navigationTitle("消息铃声")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func messageSoundRow(_ sound: JunchatMessageNotificationSound) -> some View {
        ListRow(kind: .custom {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    context.send(viewAction: .updateMessageNotificationSound(sound))
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: sound.systemImageName)
                            .font(.compound.headingMD)
                            .foregroundColor(.compound.iconAccentTertiary)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(sound.title)
                                .font(.compound.bodyLG)
                                .foregroundColor(.compound.textPrimary)
                            Text(sound.description)
                                .font(.compound.bodySM)
                                .foregroundColor(.compound.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        if context.viewState.selectedMessageNotificationSound == sound {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.compound.headingMD)
                                .foregroundColor(.compound.iconAccentTertiary)
                                .accessibilityLabel("已选择")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    playSoundPreview(sound)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.compound.headingLG)
                        .foregroundColor(.compound.iconSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("试听\(sound.title)")
            }
            .padding(.horizontal, ListRowPadding.horizontal)
            .padding(.vertical, 10)
        })
    }

    private func playSoundPreview(_ sound: JunchatMessageNotificationSound) {
        soundPreviewPlayer?.stop()

        guard let url = Bundle.app.url(forResource: sound.soundName, withExtension: nil) else {
            MXLog.error("Missing local message notification sound: \(sound.soundName)")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = 0
            player.prepareToPlay()
            soundPreviewPlayer = player
            player.play()
        } catch {
            MXLog.error("Failed to preview local message notification sound: \(error)")
        }
    }
}

struct CallRingtoneSettingsScreen: View {
    let context: SettingsScreenViewModel.Context
    @State private var ringtonePreviewPlayer: AVAudioPlayer?

    var body: some View {
        Form {
            Section {
                ForEach(JunchatCallRingtone.allCases) { ringtone in
                    callRingtoneRow(ringtone)
                }
            } footer: {
                Text("选择后会作为当前来电铃声。你可以先试听，再切换到喜欢的声音。")
                    .compoundListSectionFooter()
            }
        }
        .compoundList()
        .navigationTitle("来电铃声")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func callRingtoneRow(_ ringtone: JunchatCallRingtone) -> some View {
        ListRow(kind: .custom {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    context.send(viewAction: .updateCallRingtone(ringtone))
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: ringtone.systemImageName)
                            .font(.compound.headingMD)
                            .foregroundColor(.compound.iconAccentTertiary)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(ringtone.title)
                                .font(.compound.bodyLG)
                                .foregroundColor(.compound.textPrimary)
                            Text(ringtone.description)
                                .font(.compound.bodySM)
                                .foregroundColor(.compound.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        if context.viewState.selectedCallRingtone == ringtone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.compound.headingMD)
                                .foregroundColor(.compound.iconAccentTertiary)
                                .accessibilityLabel("已选择")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    playRingtonePreview(ringtone)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.compound.headingLG)
                        .foregroundColor(.compound.iconSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("试听\(ringtone.title)")
            }
            .padding(.horizontal, ListRowPadding.horizontal)
            .padding(.vertical, 10)
        })
    }

    private func playRingtonePreview(_ ringtone: JunchatCallRingtone) {
        ringtonePreviewPlayer?.stop()

        guard let soundName = ringtone.soundName else {
            AudioServicesPlaySystemSound(1005)
            return
        }

        guard let url = Bundle.app.url(forResource: soundName, withExtension: nil) else {
            MXLog.error("Missing local call ringtone: \(soundName)")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = 0
            player.prepareToPlay()
            ringtonePreviewPlayer = player
            player.play()
        } catch {
            MXLog.error("Failed to preview local call ringtone: \(error)")
        }
    }
}

// MARK: - Previews

struct SettingsScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let bugReportDisabledViewModel = makeViewModel(isBugReportServiceEnabled: false)

    static var previews: some View {
        ElementNavigationStack {
            SettingsScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.accountProfileURL).map { $0 != nil })
        .previewDisplayName("Default")

        ElementNavigationStack {
            SettingsScreen(context: bugReportDisabledViewModel.context)
        }
        .snapshotPreferences(expect: bugReportDisabledViewModel.context.observe(\.viewState.accountProfileURL).map { $0 != nil })
        .previewDisplayName("Bug report disabled")
    }

    static func makeViewModel(isBugReportServiceEnabled: Bool = true) -> SettingsScreenViewModel {
        let userSession = UserSessionMock(.init(clientProxy: ClientProxyMock(.init(userID: "@userid:example.com",
                                                                                   deviceID: "AAAAAAAAAAA"))))
        return SettingsScreenViewModel(userSession: userSession,
                                       appSettings: ServiceLocator.shared.settings,
                                       isBugReportServiceEnabled: isBugReportServiceEnabled)
    }
}
