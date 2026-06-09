//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Testing

@MainActor
struct SettingsScreenViewModelTests {
    private var viewModel: SettingsScreenViewModelProtocol
    private var context: SettingsScreenViewModelType.Context
    private var clientProxy: ClientProxyMock

    init() {
        AppSettings.resetAllSettings()
        clientProxy = ClientProxyMock(.init(userID: ""))
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        viewModel = SettingsScreenViewModel(userSession: userSession,
                                            appSettings: ServiceLocator.shared.settings,
                                            isBugReportServiceEnabled: true)
        context = viewModel.context
    }

    @Test
    func logout() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .logout }
        context.send(viewAction: .logout)
        try await deferred.fulfill()
    }

    @Test
    func reportBug() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .reportBug }
        context.send(viewAction: .reportBug)
        try await deferred.fulfill()
    }

    @Test
    func changePassword() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .changePassword }
        context.send(viewAction: .changePassword)
        try await deferred.fulfill()
    }

    @Test
    func analytics() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .analytics }
        context.send(viewAction: .analytics)
        try await deferred.fulfill()
    }

    @Test
    mutating func loadsContactsDirectoryVisibility() async throws {
        clientProxy.junchatHideFromContactsDirectoryReturnValue = .success(true)
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        viewModel = SettingsScreenViewModel(userSession: userSession,
                                            appSettings: ServiceLocator.shared.settings,
                                            isBugReportServiceEnabled: true)
        context = viewModel.context

        try await Task.sleep(for: .milliseconds(200))
        #expect(context.viewState.hideFromContactsDirectory)
    }

    @Test
    mutating func updatesContactsDirectoryVisibility() async throws {
        clientProxy.junchatHideFromContactsDirectoryReturnValue = .success(false)
        clientProxy.setJunchatHideFromContactsDirectoryReturnValue = .success(())
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        viewModel = SettingsScreenViewModel(userSession: userSession,
                                            appSettings: ServiceLocator.shared.settings,
                                            isBugReportServiceEnabled: true)
        context = viewModel.context

        context.send(viewAction: .updateHideFromContactsDirectory(true))
        try await Task.sleep(for: .milliseconds(200))

        #expect(context.viewState.hideFromContactsDirectory)
        #expect(!context.viewState.isWaitingContactsDirectoryVisibility)
        #expect(clientProxy.setJunchatHideFromContactsDirectoryReceivedHidden == true)
    }

    @Test
    func entertainmentTabSettingDefaultsOff() {
        #expect(!context.viewState.showEntertainmentTab)
    }

    @Test
    func updatesEntertainmentTabSetting() {
        context.send(viewAction: .updateShowEntertainmentTab(true))

        #expect(context.viewState.showEntertainmentTab)
        #expect(ServiceLocator.shared.settings.showEntertainmentTab)
    }

    @Test
    func callRingtoneSettingDefaultsToClassic() {
        #expect(context.viewState.selectedCallRingtone == .classic)
    }

    @Test
    func messageNotificationSoundSettingDefaultsToClassic() {
        #expect(context.viewState.selectedMessageNotificationSound == .classic)
    }

    @Test
    func callRingtoneSettings() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .callRingtoneSettings }
        context.send(viewAction: .callRingtoneSettings)
        try await deferred.fulfill()
    }

    @Test
    func messageNotificationSoundSettings() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .messageNotificationSoundSettings }
        context.send(viewAction: .messageNotificationSoundSettings)
        try await deferred.fulfill()
    }

    @Test
    func updatesCallRingtoneSetting() {
        context.send(viewAction: .updateCallRingtone(.brightChime))

        #expect(context.viewState.selectedCallRingtone == .brightChime)
        #expect(ServiceLocator.shared.settings.callRingtone == .brightChime)
    }

    @Test
    func updatesMessageNotificationSoundSetting() {
        context.send(viewAction: .updateMessageNotificationSound(.duo))

        #expect(context.viewState.selectedMessageNotificationSound == .duo)
        #expect(ServiceLocator.shared.settings.messageNotificationSound == .duo)
        #expect(ServiceLocator.shared.settings.notificationSoundName.publisher.value.rawValue == "junchat-message-duo.caf")
    }
}
