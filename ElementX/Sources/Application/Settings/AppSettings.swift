//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

#if IS_MAIN_APP
import EmbeddedElementCall
#endif

import Foundation
import SwiftUI

/// Common settings between app and NSE
protocol CommonSettingsProtocol: AnyObject {
    var lastNotificationBootTime: TimeInterval? { get set }
    var notificationSoundName: RemotePreference<UNNotificationSoundName> { get }
    var callRingtoneSoundName: String { get }
    var notificationBadgeRoomLedger: NotificationBadgeRoomLedger { get }

    var logLevel: LogLevel { get }
    var traceLogPacks: Set<TraceLogPack> { get }
    var bugReportRageshakeURL: RemotePreference<RageshakeConfiguration> { get }

    var enableOnlySignedDeviceIsolationMode: Bool { get }
    var threadsEnabled: Bool { get }
    var hideQuietNotificationAlerts: Bool { get }
}

enum AppBuildType {
    case debug
    case nightly
    case release
}

enum APNSEnvironment: String {
    case development
    case production

    static func current(bundle: Bundle = .main) -> APNSEnvironment? {
        guard let provisioningProfileURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: provisioningProfileURL) else {
            return nil
        }

        return environment(fromMobileProvisionData: data)
    }

    static func environment(fromMobileProvisionData data: Data) -> APNSEnvironment? {
        guard let start = data.range(of: Data("<plist".utf8))?.lowerBound,
              let endRange = data.range(of: Data("</plist>".utf8)) else {
            return nil
        }

        let end = endRange.upperBound
        guard start < end else {
            return nil
        }

        let plistData = data.subdata(in: start..<end)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let apsEnvironment = entitlements["aps-environment"] as? String else {
            return nil
        }

        return APNSEnvironment(rawValue: apsEnvironment)
    }
}

enum JunchatCallRingtone: String, CaseIterable, Codable, Identifiable {
    case systemDefault = "system-default"
    case classic = "junchat-call.caf"
    case brightChime = "junchat-call-bright-chime.caf"
    case brightRise = "junchat-call-bright-rise.caf"
    case loudChime = "junchat-call-loud-chime.caf"
    case loudRise = "junchat-call-loud-rise.caf"
    case loudAlert = "junchat-call-loud-alert.caf"
    case softBell = "junchat-call-soft-bell.caf"
    case softPulse = "junchat-call-soft-pulse.caf"

    var id: String {
        rawValue
    }

    var soundName: String? {
        self == .systemDefault ? nil : rawValue
    }

    var title: String {
        switch self {
        case .systemDefault:
            "系统默认"
        case .classic:
            "经典铃声"
        case .brightChime:
            "明亮清铃"
        case .brightRise:
            "明亮上扬"
        case .loudChime:
            "响亮清铃"
        case .loudRise:
            "响亮上扬"
        case .loudAlert:
            "强提醒铃"
        case .softBell:
            "柔和铃音"
        case .softPulse:
            "柔和脉冲"
        }
    }

    var description: String {
        switch self {
        case .systemDefault:
            "使用系统默认来电提示音。"
        case .classic:
            "沿用当前来电铃声。"
        case .brightChime:
            "清脆、醒目，适合嘈杂环境。"
        case .brightRise:
            "节奏轻快，来电辨识度更高。"
        case .loudChime:
            "更响亮、更清脆，适合嘈杂环境。"
        case .loudRise:
            "高频上扬，来电更容易被注意到。"
        case .loudAlert:
            "提醒感最强，适合需要高辨识度的场景。"
        case .softBell:
            "更温和，不容易打扰周围。"
        case .softPulse:
            "低刺激，适合安静办公。"
        }
    }

    var systemImageName: String {
        switch self {
        case .systemDefault:
            "iphone.radiowaves.left.and.right"
        case .classic:
            "phone.circle"
        case .brightChime:
            "bell.circle"
        case .brightRise:
            "waveform.circle"
        case .loudChime:
            "bell.and.waves.left.and.right"
        case .loudRise:
            "waveform.path.ecg"
        case .loudAlert:
            "bell.badge.circle"
        case .softBell:
            "moon.circle"
        case .softPulse:
            "dot.radiowaves.left.and.right"
        }
    }

    static func ringtone(for soundName: String) -> JunchatCallRingtone {
        JunchatCallRingtone(rawValue: soundName) ?? .classic
    }
}

enum JunchatMessageNotificationSound: String, CaseIterable, Codable, Identifiable {
    case classic = "junchat-message.caf"
    case bright = "junchat-message-bright.caf"
    case soft = "junchat-message-soft.caf"
    case duo = "junchat-message-duo.caf"

    var id: String {
        rawValue
    }

    var soundName: String {
        rawValue
    }

    var title: String {
        switch self {
        case .classic:
            "经典提示音"
        case .bright:
            "清脆提示音"
        case .soft:
            "柔和提示音"
        case .duo:
            "双音提示音"
        }
    }

    var description: String {
        switch self {
        case .classic:
            "沿用当前消息提示音。"
        case .bright:
            "更明亮，适合嘈杂环境。"
        case .soft:
            "更轻柔，适合安静办公。"
        case .duo:
            "短促双音，辨识度更高。"
        }
    }

    var systemImageName: String {
        switch self {
        case .classic:
            "message.circle"
        case .bright:
            "bell.circle"
        case .soft:
            "moon.circle"
        case .duo:
            "waveform.circle"
        }
    }

    static func sound(for soundName: String) -> JunchatMessageNotificationSound {
        JunchatMessageNotificationSound(rawValue: soundName) ?? .classic
    }
}

/// Store Element specific app settings.
final class AppSettings {
    let serverEnvironment: JunchatServerEnvironment

    private enum UserDefaultsKeys: String {
        case lastVersionLaunched
        case seenInvites
        case hasSeenNewSoundBanner
        case appLockNumberOfPINAttempts
        case appLockNumberOfBiometricAttempts
        case timelineStyle

        case analyticsConsentState
        case hasRunNotificationPermissionsOnboarding
        case hasRunIdentityConfirmationOnboarding
        case hasRequestedLocationAlwaysLocationAuthorization

        case frequentlyUsedSystemEmojis

        case enableNotifications
        case enableInAppNotifications
        case pusherProfileTag
        case lastNotificationBootTime
        case logLevel
        case traceLogPacks
        case viewSourceEnabled
        case optimizeMediaUploads
        case appAppearance
        case sharePresence

        case elementCallBaseURLOverride

        case voiceMessagePlaybackSpeed

        // Live Location
        case liveLocationSharingTimeoutDatesByRoomID
        case liveLocationMinimumDistanceUpdate
        case liveLocationDisclaimerDisplayed

        // Feature flags
        case publicSearchEnabled
        case fuzzyRoomListSearchEnabled
        case lowPriorityFilterEnabled
        case enableOnlySignedDeviceIsolationMode
        case knockingEnabled
        case threadsEnabled
        case roomThreadListEnabled
        case linkPreviewsEnabled
        case focusEventOnNotificationTap
        case linkNewDeviceEnabled
        case automaticBackPaginationEnabled

        // Doug's tweaks 🔧
        case roomListActivityVisibility
        case hideQuietNotificationAlerts

        case developerOptionsEnabled
        case showEntertainmentTab
        case hasDismissedChatBackupBanner
        case callRingtoneSoundName
        case messageNotificationSoundName
        case junchatPrivacyModeRoomIDs
        case junchatEmergencyPrivacyModeEnabled
    }

    private static var suiteName: String = InfoPlistReader.main.appGroupIdentifier

    /// UserDefaults to be used on reads and writes.
    private static var store: UserDefaults! = UserDefaults(suiteName: suiteName)

    static var appBuildType: AppBuildType {
        #if DEBUG
        return .debug
        #else
        switch InfoPlistReader.main.baseBundleIdentifier {
        case "com.heyujk.junchat.nightly":
            return .nightly
        default:
            return .release
        }
        #endif
    }

    static func resetAllSettings() {
        MXLog.warning("Resetting the AppSettings.")
        store.removePersistentDomain(forName: suiteName)
    }

    static func resetSessionSpecificSettings(userDefaults: UserDefaults = store) {
        MXLog.warning("Resetting the user session specific AppSettings.")
        userDefaults.removeObject(forKey: UserDefaultsKeys.hasRunIdentityConfirmationOnboarding.rawValue)
    }

    static func configureWithSuiteName(_ name: String) {
        suiteName = name

        guard let userDefaults = UserDefaults(suiteName: name) else {
            fatalError("Fail to load shared UserDefaults")
        }

        store = userDefaults
    }

    static var sharedUserDefaults: UserDefaults {
        store
    }

    private(set) lazy var notificationBadgeRoomLedger = NotificationBadgeRoomLedger(userDefaults: Self.store,
                                                                                    lockFileURL: URL.appGroupContainerDirectory
                                                                                        .appending(component: ".junchat-notification-badge.lock"))

    init(serverEnvironment: JunchatServerEnvironment = .current) {
        self.serverEnvironment = serverEnvironment
        accountProviders = [serverEnvironment.matrixAccountProvider]
        backgroundAppRefreshTaskIdentifier = serverEnvironment.backgroundAppRefreshTaskIdentifier
        oidcRedirectURL = serverEnvironment.oidcRedirectURL
        pushGatewayBaseURL = serverEnvironment.pushGatewayBaseURL
        pushGatewayNotifyEndpoint = serverEnvironment.pushGatewayNotifyURL
        diagnosticsEndpoint = serverEnvironment.diagnosticsEndpoint
        let rageshakeConfiguration: RageshakeConfiguration
        if serverEnvironment.rageshakeEnabled,
           let rageshakeURLString = Secrets.rageshakeURL,
           let rageshakeURL = URL(string: rageshakeURLString) {
            rageshakeConfiguration = .url(rageshakeURL)
        } else {
            rageshakeConfiguration = .disabled
        }
        bugReportRageshakeURL = .init(rageshakeConfiguration)
        notificationSoundName.applyRemoteValue(.init(messageNotificationSoundName))
    }

    // MARK: - Hooks

    // swiftlint:disable:next function_parameter_count
    func override(accountProviders: [String],
                  allowOtherAccountProviders: Bool,
                  hideBrandChrome: Bool,
                  pushGatewayBaseURL: URL,
                  oidcRedirectURL: URL,
                  websiteURL: URL,
                  logoURL: URL,
                  copyrightURL: URL,
                  acceptableUseURL: URL,
                  privacyURL: URL,
                  encryptionURL: URL,
                  deviceVerificationURL: URL,
                  chatBackupDetailsURL: URL,
                  identityPinningViolationDetailsURL: URL,
                  historySharingDetailsURL: URL,
                  elementWebHosts: [String],
                  accountProvisioningHost: String,
                  bugReportApplicationID: String,
                  analyticsTermsURL: URL?,
                  mapTilerConfiguration: MapTilerConfiguration) {
        self.accountProviders = accountProviders
        self.allowOtherAccountProviders = allowOtherAccountProviders
        self.hideBrandChrome = hideBrandChrome
        self.pushGatewayBaseURL = pushGatewayBaseURL
        pushGatewayNotifyEndpoint = pushGatewayBaseURL.appending(path: "_matrix/push/v1/notify")
        self.oidcRedirectURL = oidcRedirectURL
        self.websiteURL = websiteURL
        self.logoURL = logoURL
        self.copyrightURL = copyrightURL
        self.acceptableUseURL = acceptableUseURL
        self.privacyURL = privacyURL
        self.encryptionURL = encryptionURL
        self.deviceVerificationURL = deviceVerificationURL
        self.chatBackupDetailsURL = chatBackupDetailsURL
        self.identityPinningViolationDetailsURL = identityPinningViolationDetailsURL
        self.historySharingDetailsURL = historySharingDetailsURL
        self.elementWebHosts = elementWebHosts
        self.accountProvisioningHost = accountProvisioningHost
        self.bugReportApplicationID = bugReportApplicationID
        self.analyticsTermsURL = analyticsTermsURL
        self.mapTilerConfiguration = mapTilerConfiguration
    }

    // MARK: - Application

    /// The last known version of the app that was launched on this device, which is
    /// used to detect when migrations should be run. When `nil` the app may have been
    /// deleted between runs so should clear data in the shared container and keychain.
    @UserPreference(key: UserDefaultsKeys.lastVersionLaunched, storageType: .userDefaults(store))
    var lastVersionLaunched: String?

    /// The Set of room identifiers of invites that the user already saw in the invites list.
    /// This Set is being used to implement badges for unread invites.
    @UserPreference(key: UserDefaultsKeys.seenInvites, defaultValue: [], storageType: .userDefaults(store))
    var seenInvites: Set<String>

    /// Defaults to `true` for new users, and we use a migration to set it to `false` for existing users.
    @UserPreference(key: UserDefaultsKeys.hasSeenNewSoundBanner, defaultValue: true, storageType: .userDefaults(store))
    var hasSeenNewSoundBanner

    /// The initial set of account providers shown to the user in the authentication flow.
    ///
    /// Account provider is the friendly term for the server name. It should not contain an `https` prefix and should
    /// match the last part of the user ID. For example `example.com` and not `https://matrix.example.com`.
    private(set) var accountProviders: [String]
    /// Whether or not the user is allowed to manually enter their own account provider or must select from one of `defaultAccountProviders`.
    private(set) var allowOtherAccountProviders = false
    /// Whether the components surrounding the app brand/logo should be hidden or not
    private(set) var hideBrandChrome = false

    /// The task identifier used for background app refresh. Also used in main target's the Info.plist
    let backgroundAppRefreshTaskIdentifier: String

    /// A URL where users can go read more about the app.
    private(set) var websiteURL: URL = "https://junchat.yyzs120.cn"
    /// A URL that contains the app's logo that may be used when showing content in a web view.
    private(set) var logoURL: URL = "https://junchat.yyzs120.cn/junchat-assets/junchat-logo-v2.svg"
    /// A URL that contains that app's copyright notice.
    private(set) var copyrightURL: URL = "https://junchat.yyzs120.cn"
    /// A URL that contains the app's Terms of use.
    private(set) var acceptableUseURL: URL = "https://junchat.yyzs120.cn/junchat-assets/terms.html"
    /// A URL that contains the app's Privacy Policy.
    private(set) var privacyURL: URL = "https://junchat.yyzs120.cn"
    /// A URL where users can go read more about encryption in general.
    private(set) var encryptionURL: URL = "https://junchat.yyzs120.cn"
    /// A URL where users can go read more about device verification..
    private(set) var deviceVerificationURL: URL = "https://junchat.yyzs120.cn"
    /// A URL where users can go read more about the chat backup.
    private(set) var chatBackupDetailsURL: URL = "https://junchat.yyzs120.cn"
    /// A URL where users can go read more about identity pinning violations
    private(set) var identityPinningViolationDetailsURL: URL = "https://junchat.yyzs120.cn"
    /// A URL describing how history sharing works
    private(set) var historySharingDetailsURL: URL = "https://junchat.yyzs120.cn"

    /// Any domains that Element web may be hosted on - used for handling links.
    private(set) var elementWebHosts = ["junchat.yyzs120.cn"]
    /// The domain that account provisioning links will be hosted on - used for handling the links.
    private(set) var accountProvisioningHost = "junchat.yyzs120.cn"
    /// The App Store URL for Element Pro, shown to the user when a homeserver requires that app.
    /// **Note:** This property isn't overridable as it in unexpected for forks to come across the error (or to even have a "Pro" app).
    let elementProAppStoreURL: URL = "https://apps.apple.com/app/element-pro-for-work/id6502951615"

    @UserPreference(key: UserDefaultsKeys.appAppearance, defaultValue: .system, storageType: .userDefaults(store))
    var appAppearance: AppAppearance

    @UserPreference(key: UserDefaultsKeys.showEntertainmentTab, defaultValue: false, storageType: .userDefaults(store))
    var showEntertainmentTab: Bool

    @UserPreference(key: UserDefaultsKeys.hasDismissedChatBackupBanner, defaultValue: false, storageType: .userDefaults(store))
    var hasDismissedChatBackupBanner: Bool

    @UserPreference(key: UserDefaultsKeys.junchatPrivacyModeRoomIDs, defaultValue: Set<String>(), storageType: .userDefaults(store))
    var junchatPrivacyModeRoomIDs: Set<String>

    @UserPreference(key: UserDefaultsKeys.junchatEmergencyPrivacyModeEnabled, defaultValue: false, storageType: .userDefaults(store))
    var junchatEmergencyPrivacyModeEnabled: Bool

    // MARK: - Security

    /// JunChat keeps Matrix encryption enabled and offers cross-device verification onboarding until the user hides it.
    let shouldRunIdentityConfirmationOnboarding = true
    /// The app must be locked with a PIN code as part of the authentication flow.
    let appLockIsMandatory = false
    /// The amount of time the app can remain in the background for without requesting the PIN/TouchID/FaceID.
    let appLockGracePeriod: TimeInterval = 0
    /// Any codes that the user isn't allowed to use for their PIN.
    let appLockPINCodeBlockList = ["0000", "1234", "7878"]
    /// The number of attempts the user has made to unlock the app with a PIN code (resets when unlocked).
    @UserPreference(key: UserDefaultsKeys.appLockNumberOfPINAttempts, defaultValue: 0, storageType: .userDefaults(store))
    var appLockNumberOfPINAttempts: Int

    // MARK: - Authentication

    /// Any pre-defined static client registrations for OIDC issuers.
    let oidcStaticRegistrations: [URL: String] = [:]
    /// The redirect URL used for OIDC. This no longer uses universal links so we don't need the bundle ID to avoid conflicts between Element X, Nightly and PR builds.
    private(set) var oidcRedirectURL: URL

    private(set) lazy var oidcConfiguration = OIDCConfiguration(clientName: InfoPlistReader.main.bundleDisplayName,
                                                                redirectURI: oidcRedirectURL,
                                                                clientURI: websiteURL,
                                                                logoURI: logoURL,
                                                                tosURI: acceptableUseURL,
                                                                policyURI: privacyURL,
                                                                staticRegistrations: oidcStaticRegistrations.mapKeys { $0.absoluteString })

    /// Whether or not the Create Account button is shown on the start screen.
    ///
    /// **Note:** Setting this to false doesn't prevent someone from creating an account when the selected homeserver's MAS allows registration.
    let showCreateAccountButton = false

    // MARK: - Notifications

    var pusherAppID: String {
        let suffix: String
        switch APNSEnvironment.current() ?? AppSettings.defaultAPNSEnvironment {
        case .development:
            suffix = ".ios.dev"
        case .production:
            suffix = ".ios.prod"
        }

        return InfoPlistReader.main.baseBundleIdentifier + suffix
    }

    private(set) var pushGatewayBaseURL: URL
    private(set) var pushGatewayNotifyEndpoint: URL

    private(set) var diagnosticsEndpoint: URL

    @UserPreference(key: UserDefaultsKeys.enableNotifications, defaultValue: true, storageType: .userDefaults(store))
    var enableNotifications

    @UserPreference(key: UserDefaultsKeys.enableInAppNotifications, defaultValue: true, storageType: .userDefaults(store))
    var enableInAppNotifications

    @UserPreference(key: UserDefaultsKeys.hideQuietNotificationAlerts, defaultValue: false, storageType: .userDefaults(store))
    var hideQuietNotificationAlerts

    /// Tag describing which set of device specific rules a pusher executes.
    @UserPreference(key: UserDefaultsKeys.pusherProfileTag, storageType: .userDefaults(store))
    var pusherProfileTag: String?

    /// The device's last boot time as recorded by the NSE.
    @UserPreference(key: UserDefaultsKeys.lastNotificationBootTime, storageType: .userDefaults(store))
    var lastNotificationBootTime: TimeInterval?

    /// The name of sound played when delivering noisy notifications.
    var notificationSoundName: RemotePreference<UNNotificationSoundName> = .init(.init("junchat-message.caf"))

    /// The local notification sound used for incoming messages.
    @UserPreference(key: UserDefaultsKeys.messageNotificationSoundName,
                    defaultValue: JunchatMessageNotificationSound.classic.rawValue,
                    storageType: .userDefaults(store))
    var messageNotificationSoundName: String

    var messageNotificationSound: JunchatMessageNotificationSound {
        get {
            JunchatMessageNotificationSound.sound(for: messageNotificationSoundName)
        }
        set {
            messageNotificationSoundName = newValue.rawValue
            notificationSoundName.applyRemoteValue(.init(newValue.soundName))
        }
    }

    /// The local CallKit ringtone used for incoming calls.
    @UserPreference(key: UserDefaultsKeys.callRingtoneSoundName,
                    defaultValue: JunchatCallRingtone.classic.rawValue,
                    storageType: .userDefaults(store))
    var callRingtoneSoundName: String

    var callRingtone: JunchatCallRingtone {
        get {
            JunchatCallRingtone.ringtone(for: callRingtoneSoundName)
        }
        set {
            callRingtoneSoundName = newValue.rawValue
        }
    }

    private static var defaultAPNSEnvironment: APNSEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    // MARK: - Logging

    @UserPreference(key: UserDefaultsKeys.logLevel, defaultValue: LogLevel.info, storageType: .userDefaults(store))
    var logLevel

    @UserPreference(key: UserDefaultsKeys.traceLogPacks, defaultValue: [], storageType: .userDefaults(store))
    var traceLogPacks: Set<TraceLogPack>

    // MARK: - Bug report

    let bugReportRageshakeURL: RemotePreference<RageshakeConfiguration>
    let bugReportSentryURL: URL? = nil
    let bugReportSentryRustURL: URL? = nil
    /// The name allocated by the bug report server
    private(set) var bugReportApplicationID = "junchat-ios"

    // MARK: - Analytics

    /// The configuration to use for analytics. Set to `nil` to disable analytics.
    let analyticsConfiguration: AnalyticsConfiguration? = nil
    /// The URL to open with more information about analytics terms. When this is `nil` the "Learn more" link will be hidden.
    private(set) var analyticsTermsURL: URL?
    /// Whether or not there the app is able ask for user consent to enable analytics or sentry reporting.
    var canPromptForAnalytics: Bool {
        false
    }

    private static func makeAnalyticsConfiguration() -> AnalyticsConfiguration? {
        guard let host = Secrets.postHogHost, let apiKey = Secrets.postHogAPIKey else { return nil }
        return AnalyticsConfiguration(host: host, apiKey: apiKey)
    }

    /// Whether the user has opted in to send analytics.
    @UserPreference(key: UserDefaultsKeys.analyticsConsentState, defaultValue: AnalyticsConsentState.unknown, storageType: .userDefaults(store))
    var analyticsConsentState

    @UserPreference(key: UserDefaultsKeys.hasRunNotificationPermissionsOnboarding, defaultValue: false, storageType: .userDefaults(store))
    var hasRunNotificationPermissionsOnboarding

    /// Legacy completion marker retained for migrations and downgrade compatibility.
    /// Permanent prompt decisions are stored per account by `VerificationPromptDecisionStore`.
    @UserPreference(key: UserDefaultsKeys.hasRunIdentityConfirmationOnboarding, defaultValue: false, storageType: .userDefaults(store))
    var hasRunIdentityConfirmationOnboarding

    @UserPreference(key: UserDefaultsKeys.hasRequestedLocationAlwaysLocationAuthorization, defaultValue: false, storageType: .userDefaults(store))
    var hasRequestedLocationAlwaysLocationAuthorization

    @UserPreference(key: UserDefaultsKeys.frequentlyUsedSystemEmojis, defaultValue: [FrequentlyUsedEmoji](), storageType: .userDefaults(store))
    var frequentlyUsedSystemEmojis

    // MARK: - Live Location

    @UserPreference(key: UserDefaultsKeys.liveLocationSharingTimeoutDatesByRoomID, defaultValue: [String: Date](), storageType: .userDefaults(store))
    var liveLocationSharingTimeoutDatesByRoomID

    @UserPreference(key: UserDefaultsKeys.liveLocationMinimumDistanceUpdate, defaultValue: 10, storageType: .userDefaults(store))
    var liveLocationMinimumDistanceUpdate

    @UserPreference(key: UserDefaultsKeys.liveLocationDisclaimerDisplayed, defaultValue: false, storageType: .userDefaults(store))
    var liveLocationDisclaimerDisplayed

    // MARK: - Home Screen

    @UserPreference(key: UserDefaultsKeys.roomListActivityVisibility, defaultValue: .current, storageType: .userDefaults(store))
    var roomListActivityVisibility: RoomListActivityVisibility

    // MARK: - Room Screen

    @UserPreference(key: UserDefaultsKeys.viewSourceEnabled, defaultValue: appBuildType == .debug, storageType: .userDefaults(store))
    var viewSourceEnabled

    @UserPreference(key: UserDefaultsKeys.optimizeMediaUploads, defaultValue: true, storageType: .userDefaults(store))
    var optimizeMediaUploads

    @UserPreference(key: UserDefaultsKeys.voiceMessagePlaybackSpeed, defaultValue: AudioPlaybackSpeed.default, storageType: .userDefaults(store))
    var voiceMessagePlaybackSpeed: AudioPlaybackSpeed

    /// Whether or not to show a warning on the media caption composer so the user knows
    /// that captions might not be visible to users who are using other Matrix clients.
    let shouldShowMediaCaptionWarning = true

    // MARK: - Element Call

    #if IS_MAIN_APP
    // swiftlint:disable:next force_unwrapping
    let elementCallBaseURL: URL = EmbeddedElementCall.appURL!
    #endif

    let elementCallPosthogAPIHost = ""
    let elementCallPosthogAPIKey = ""
    let elementCallPosthogSentryDSN = ""

    @UserPreference(key: UserDefaultsKeys.elementCallBaseURLOverride, defaultValue: nil, storageType: .userDefaults(store))
    var elementCallBaseURLOverride: URL?

    // MARK: - Users

    /// Whether to hide the display name and avatar of ignored users as these may contain objectionable content.
    let hideIgnoredUserProfiles = true

    // MARK: - Maps

    /// maptiler base url
    private(set) var mapTilerConfiguration = MapTilerConfiguration(baseURL: "https://api.maptiler.com/maps",
                                                                   apiKey: "fU3vlMsMn4Jb6dnEIFsx",
                                                                   lightStyleID: "basic-v2",
                                                                   darkStyleID: "basic-v2-dark")

    // MARK: - Presence

    @UserPreference(key: UserDefaultsKeys.sharePresence, defaultValue: true, storageType: .userDefaults(store))
    var sharePresence

    // MARK: - Feature Flags

    /// Others
    @UserPreference(key: UserDefaultsKeys.publicSearchEnabled, defaultValue: false, storageType: .userDefaults(store))
    var publicSearchEnabled

    @UserPreference(key: UserDefaultsKeys.fuzzyRoomListSearchEnabled, defaultValue: false, storageType: .userDefaults(store))
    var fuzzyRoomListSearchEnabled

    @UserPreference(key: UserDefaultsKeys.lowPriorityFilterEnabled, defaultValue: false, storageType: .userDefaults(store))
    var lowPriorityFilterEnabled

    /// Configuration to enable only signed device isolation mode for  crypto. In this mode only devices signed by their owner will be considered in e2ee rooms.
    @UserPreference(key: UserDefaultsKeys.enableOnlySignedDeviceIsolationMode, defaultValue: false, storageType: .userDefaults(store))
    var enableOnlySignedDeviceIsolationMode

    @UserPreference(key: UserDefaultsKeys.knockingEnabled, defaultValue: false, storageType: .userDefaults(store))
    var knockingEnabled

    @UserPreference(key: UserDefaultsKeys.threadsEnabled, defaultValue: false, storageType: .userDefaults(store))
    var threadsEnabled

    @UserPreference(key: UserDefaultsKeys.roomThreadListEnabled, defaultValue: false, storageType: .userDefaults(store))
    var roomThreadListEnabled

    @UserPreference(key: UserDefaultsKeys.focusEventOnNotificationTap, defaultValue: false, storageType: .userDefaults(store))
    var focusEventOnNotificationTap

    @UserPreference(key: UserDefaultsKeys.linkPreviewsEnabled, defaultValue: false, storageType: .userDefaults(store))
    var linkPreviewsEnabled

    @UserPreference(key: UserDefaultsKeys.linkNewDeviceEnabled, defaultValue: false, storageType: .userDefaults(store))
    var linkNewDeviceEnabled

    @UserPreference(key: UserDefaultsKeys.automaticBackPaginationEnabled, defaultValue: false, storageType: .userDefaults(store))
    var automaticBackPaginationEnabled

    @UserPreference(key: UserDefaultsKeys.developerOptionsEnabled, defaultValue: appBuildType != .release, storageType: .userDefaults(store))
    var developerOptionsEnabled
}

extension AppSettings: CommonSettingsProtocol { }
