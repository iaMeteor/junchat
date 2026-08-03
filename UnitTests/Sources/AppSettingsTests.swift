//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing
import UserNotifications

@MainActor
struct AppSettingsTests {
    init() {
        AppSettings.resetAllSettings()
    }
    
    @Test
    func entertainmentTabDefaultsToHidden() {
        #expect(!ServiceLocator.shared.settings.showEntertainmentTab)
    }
    
    @Test
    func entertainmentTabPersistsLocally() {
        ServiceLocator.shared.settings.showEntertainmentTab = true
        
        #expect(AppSettings().showEntertainmentTab)
    }

    @Test
    func chatBackupBannerDismissalDefaultsToVisible() {
        #expect(!ServiceLocator.shared.settings.hasDismissedChatBackupBanner)
    }

    @Test
    func chatBackupBannerDismissalPersistsLocally() {
        ServiceLocator.shared.settings.hasDismissedChatBackupBanner = true

        #expect(AppSettings().hasDismissedChatBackupBanner)
    }
    
    @Test
    func callRingtoneDefaultsToClassic() {
        #expect(ServiceLocator.shared.settings.callRingtone == .classic)
        #expect(ServiceLocator.shared.settings.callRingtoneSoundName == "junchat-call.caf")
    }
    
    @Test
    func callRingtonePersistsLocally() {
        ServiceLocator.shared.settings.callRingtone = .softPulse
        
        #expect(AppSettings().callRingtone == .softPulse)
        #expect(AppSettings().callRingtoneSoundName == "junchat-call-soft-pulse.caf")
    }
    
    @Test
    func callRingtonesAreBundled() {
        for ringtone in JunchatCallRingtone.allCases {
            guard let soundName = ringtone.soundName else { continue }

            #expect(Bundle.app.url(forResource: soundName, withExtension: nil) != nil)
        }
    }

    @Test
    func messageNotificationSoundDefaultsToClassic() {
        #expect(ServiceLocator.shared.settings.messageNotificationSound == .classic)
        #expect(ServiceLocator.shared.settings.messageNotificationSoundName == "junchat-message.caf")
        #expect(ServiceLocator.shared.settings.notificationSoundName.publisher.value.rawValue == "junchat-message.caf")
    }

    @Test
    func messageNotificationSoundPersistsLocally() {
        ServiceLocator.shared.settings.messageNotificationSound = .bright

        let settings = AppSettings()
        #expect(settings.messageNotificationSound == .bright)
        #expect(settings.messageNotificationSoundName == "junchat-message-bright.caf")
        #expect(settings.notificationSoundName.publisher.value.rawValue == "junchat-message-bright.caf")
    }

    @Test
    func messageNotificationSoundsAreBundled() {
        for sound in JunchatMessageNotificationSound.allCases {
            #expect(Bundle.app.url(forResource: sound.soundName, withExtension: nil) != nil)
        }
    }
    
    @Test
    func callProviderConfigurationUsesSelectedRingtone() {
        let configuration = ElementCallService.makeProviderConfiguration(ringtoneSoundName: JunchatCallRingtone.brightRise.rawValue)
        
        #expect(configuration.ringtoneSound == "junchat-call-bright-rise.caf")
    }

    @Test
    func callProviderConfigurationCanUseSystemDefaultRingtone() {
        let configuration = ElementCallService.makeProviderConfiguration(ringtoneSoundName: JunchatCallRingtone.systemDefault.rawValue)

        #expect(configuration.ringtoneSound == nil)
    }
    
    @Test
    func locationSharingIsEnabledByDefault() {
        let configuration = ServiceLocator.shared.settings.mapTilerConfiguration
        
        #expect(configuration.isEnabled)
    }

    @Test
    func mapPreviewUsesDefaultMapTilerStyles() {
        let configuration = ServiceLocator.shared.settings.mapTilerConfiguration

        #expect(configuration.lightStyleID == "basic-v2")
        #expect(configuration.darkStyleID == "basic-v2-dark")
    }
    
    @Test
    func notificationExtensionUsesSelectedCallRingtone() {
        ServiceLocator.shared.settings.callRingtone = .softBell
        
        let soundName = NotificationHandler.junchatCallNotificationSoundName(settings: ServiceLocator.shared.settings)
        
        #expect(soundName?.rawValue == "junchat-call-soft-bell.caf")
    }

    @Test
    func serverValuesUseInjectedEnvironment() throws {
        let environment = try #require(JunchatServerEnvironment(infoDictionary: [
            "JunchatMatrixAccountProvider": "canary.junchat.yyzs120.cn",
            "JunchatOIDCRedirectURL": "https://canary.junchat.yyzs120.cn/oidc/login",
            "JunchatPushGatewayBaseURL": "https://canary.junchat.yyzs120.cn/push",
            "JunchatPushGatewayNotifyURL": "https://canary.junchat.yyzs120.cn/_matrix/push/v1/notify?junchat-sygnal=canary",
            "JunchatDiagnosticsEndpoint": "https://canary.junchat.yyzs120.cn/diagnostics/api/events",
            "JunchatRageshakeEnabled": "NO",
            "JunchatBackgroundAppRefreshTaskIdentifier": "com.heyujk.junchat.canary.background.refresh"
        ]))

        let settings = AppSettings(serverEnvironment: environment)

        #expect(settings.accountProviders == ["canary.junchat.yyzs120.cn"])
        #expect(settings.oidcRedirectURL == URL(string: "https://canary.junchat.yyzs120.cn/oidc/login"))
        #expect(settings.pushGatewayBaseURL == URL(string: "https://canary.junchat.yyzs120.cn/push"))
        #expect(settings.pushGatewayNotifyEndpoint == URL(string: "https://canary.junchat.yyzs120.cn/_matrix/push/v1/notify?junchat-sygnal=canary"))
        #expect(settings.diagnosticsEndpoint == URL(string: "https://canary.junchat.yyzs120.cn/diagnostics/api/events"))
        #expect(settings.backgroundAppRefreshTaskIdentifier == "com.heyujk.junchat.canary.background.refresh")
        #expect(settings.bugReportRageshakeURL.publisher.value == RageshakeConfiguration.disabled)
    }

    @Test
    func productionPushNotifyEndpointUsesTheVersionedSygnalRoute() {
        let settings = AppSettings(serverEnvironment: .production)

        #expect(settings.pushGatewayNotifyEndpoint == URL(string: "https://sygnal-junchat.yyzs120.cn/_matrix/push/v1/notify?junchat-sygnal=v2&junchat-badge=messages-v1"))
    }
    
    @Test
    func apnsEnvironmentReadsDevelopmentProvisioningProfile() {
        let data = mobileProvisionData(apsEnvironment: "development")
        
        #expect(APNSEnvironment.environment(fromMobileProvisionData: data) == .development)
    }
    
    @Test
    func apnsEnvironmentReadsProductionProvisioningProfile() {
        let data = mobileProvisionData(apsEnvironment: "production")
        
        #expect(APNSEnvironment.environment(fromMobileProvisionData: data) == .production)
    }
    
    private func mobileProvisionData(apsEnvironment: String) -> Data {
        Data("""
        opaque header
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key>
                <string>\(apsEnvironment)</string>
            </dict>
        </dict>
        </plist>
        opaque footer
        """.utf8)
    }
}
