#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

failures=0

check_file_contains() {
    local file="$1"
    local pattern="$2"
    local label="$3"

    if grep -Fq "$pattern" "$file"; then
        printf 'ok - %s\n' "$label"
    else
        printf 'not ok - %s\n  missing: %s in %s\n' "$label" "$pattern" "$file" >&2
        failures=$((failures + 1))
    fi
}

check_audio_duration_between() {
    local file="$1"
    local min_seconds="$2"
    local max_seconds="$3"
    local label="$4"

    if [[ ! -f "$file" ]]; then
        printf 'not ok - %s\n  missing: %s\n' "$label" "$file" >&2
        failures=$((failures + 1))
        return
    fi

    local duration
    duration="$(afinfo "$file" | awk '/estimated duration:/ { print $3; exit }')"

    if awk -v duration="$duration" -v min="$min_seconds" -v max="$max_seconds" 'BEGIN { exit !(duration >= min && duration <= max) }'; then
        printf 'ok - %s\n' "$label"
    else
        printf 'not ok - %s\n  expected %.1fs-%.1fs, got %ss in %s\n' "$label" "$min_seconds" "$max_seconds" "$duration" "$file" >&2
        failures=$((failures + 1))
    fi
}

check_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local label="$3"

    if grep -Fq "$pattern" "$file"; then
        printf 'not ok - %s\n  unexpected: %s in %s\n' "$label" "$pattern" "$file" >&2
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$label"
    fi
}

check_file_contains app.yml "APP_DISPLAY_NAME: 君聊" "app display name"
check_file_contains app.yml "PRODUCTION_APP_NAME: Junchat" "production app name"
check_file_contains app.yml "APP_GROUP_IDENTIFIER: group.com.heyujk.junchat" "app group"
check_file_contains app.yml "BASE_BUNDLE_IDENTIFIER: com.heyujk.junchat" "base bundle identifier"
check_file_contains app.yml "DEVELOPMENT_TEAM: W834S4TA7S" "development team"
check_file_contains app.yml "JUNCHAT_MATRIX_ACCOUNT_PROVIDER: junchat.yyzs120.cn" "production matrix account provider"
check_file_contains app.yml "JUNCHAT_OIDC_REDIRECT_URL: https://junchat.yyzs120.cn/oidc/login" "production oidc redirect"
check_file_contains app.yml "JUNCHAT_PUSH_GATEWAY_BASE_URL: https://sygnal-junchat.yyzs120.cn" "production push gateway"
check_file_contains app.yml "JUNCHAT_DIAGNOSTICS_ENDPOINT: https://junchat.yyzs120.cn/junchat-errors/api/events" "production diagnostics endpoint"
check_file_contains app.yml "JUNCHAT_BACKGROUND_APP_REFRESH_TASK_IDENTIFIER: com.heyujk.junchat.background.refresh" "production background task identifier"
check_file_contains app.yml "JUNCHAT_LIVEKIT_JWT_URL: https://junchat.yyzs120.cn/livekit/jwt" "production livekit jwt endpoint"

check_file_contains ElementX/SupportingFiles/target.yml '$(JUNCHAT_BACKGROUND_APP_REFRESH_TASK_IDENTIFIER)' "configured background task identifier"
check_file_contains ElementX/SupportingFiles/target.yml 'applinks:$(JUNCHAT_ASSOCIATED_DOMAIN)' "configured junchat applinks domain"
check_file_contains ElementX/SupportingFiles/target.yml 'webcredentials:$(JUNCHAT_ASSOCIATED_DOMAIN)' "configured junchat webcredentials domain"
check_file_not_contains ElementX/SupportingFiles/target.yml "applinks:element.io" "no Element applinks"
check_file_not_contains ElementX/SupportingFiles/target.yml "webcredentials:*.element.io" "no Element webcredentials"
check_file_contains ElementX/SupportingFiles/Info.plist "<string>audio</string>" "background audio mode for active calls"
check_file_not_contains ElementX/SupportingFiles/Info.plist "<string>location</string>" "no background location mode"
check_file_contains ElementX/SupportingFiles/Info.plist "NSLocationAlwaysAndWhenInUseUsageDescription" "always location purpose string"
check_file_contains ElementX/SupportingFiles/Info.plist "NSLocationWhenInUseUsageDescription" "when-in-use location purpose string"
check_file_contains ElementX/SupportingFiles/target.yml "          audio" "generated background audio mode for active calls"
check_file_not_contains ElementX/SupportingFiles/target.yml "          location" "no generated background location mode"
check_file_contains ElementX/SupportingFiles/target.yml "NSLocationAlwaysAndWhenInUseUsageDescription" "generated always location purpose string"
check_file_contains ElementX/SupportingFiles/target.yml "NSLocationWhenInUseUsageDescription" "generated when-in-use location purpose string"

check_file_contains ElementX/Sources/Services/Environment/JunchatServerEnvironment.swift 'matrixAccountProvider: "junchat.yyzs120.cn"' "default homeserver"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift 'accountProviders = [serverEnvironment.matrixAccountProvider]' "environment-backed homeserver"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift "private(set) var allowOtherAccountProviders = false" "disable custom homeservers"
check_file_contains ElementX/Sources/Services/Environment/JunchatServerEnvironment.swift 'pushGatewayBaseURL: URL(string: "https://sygnal-junchat.yyzs120.cn")' "push gateway"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift 'pushGatewayBaseURL = serverEnvironment.pushGatewayBaseURL' "environment-backed push gateway"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift "let showCreateAccountButton = false" "hide create account"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift 'apiKey: "fU3vlMsMn4Jb6dnEIFsx"' "enable location sharing"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift 'var notificationSoundName: RemotePreference<UNNotificationSoundName> = .init(.init("junchat-message.caf"))' "message notification sound"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift "enum APNSEnvironment" "apns environment parser"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift "environment(fromMobileProvisionData" "mobileprovision apns parser"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift "APNSEnvironment.current() ?? AppSettings.defaultAPNSEnvironment" "runtime apns environment selection"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift 'suffix = ".ios.dev"' "development pusher app id suffix"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift 'suffix = ".ios.prod"' "production pusher app id suffix"
check_file_contains ElementX/Sources/Services/Notification/Manager/APNSPayload.swift "case sound" "apns payload sound key"
check_file_contains ElementX/Sources/Services/Notification/Manager/NotificationManager.swift 'sound: "junchat-message.caf"' "pusher default payload sound"
check_file_contains ElementX/Sources/Services/Notification/Manager/NotificationManager.swift "notificationCenter.setBadgeCount(0)" "clear app badge after all read"
check_file_contains ElementX/Sources/Services/Notification/Manager/NotificationManager.swift "Bundle.junchatPreferredLocalizations.first" "pusher language restricted to junchat localizations"
check_file_contains ElementX/Sources/Services/Notification/Manager/UserNotificationCenterProtocol.swift "func setBadgeCount(_ count: Int) async throws" "notification center badge protocol"
check_file_contains UnitTests/Sources/NotificationManager/NotificationManagerTests.swift "whenRemovingNotificationsForFullyReadRoomsAndAllRoomsAreRead_badgeIsCleared" "badge clear unit test"
check_file_contains UnitTests/Sources/AppSettingsTests.swift "apnsEnvironmentReadsDevelopmentProvisioningProfile" "development apns parser test"
check_file_contains UnitTests/Sources/AppSettingsTests.swift "apnsEnvironmentReadsProductionProvisioningProfile" "production apns parser test"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift 'private(set) var bugReportApplicationID = "junchat-ios"' "bug report application id"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift "case showEntertainmentTab" "entertainment tab setting key"
check_file_contains ElementX/Sources/Application/Settings/AppSettings.swift "defaultValue: false, storageType: .userDefaults(store))" "entertainment tab disabled by default"

check_file_contains ElementX/Sources/Services/ElementCall/ElementCallService.swift 'configuration.ringtoneSound = JunchatCallRingtone.ringtone(for: ringtoneSoundName).soundName' "call ringtone"
check_file_contains NSE/Sources/NotificationContentBuilder.swift 'notificationContent.sound = notificationSound(for: notificationItem)' "nse always assigns notification sound"
check_file_contains NSE/Sources/NotificationContentBuilder.swift 'callNotificationSoundName: UNNotificationSoundName' "nse call sound dependency"
check_file_contains NSE/Sources/NotificationHandler.swift 'JunchatCallRingtone.ringtone(for: settings.callRingtoneSoundName).soundName' "nse call notification sound"
check_file_contains ElementX/Sources/Screens/CallScreen/View/CallScreen.swift 'matrix-setting-custom-livekit-url' "element call livekit local storage fallback"
check_file_contains ElementX/Sources/Screens/CallScreen/View/CallScreen.swift 'window.fetch = async' "element call config fetch patch"
check_file_contains ElementX/Sources/Services/Environment/JunchatServerEnvironment.swift 'liveKitJWTURL: URL(string: "https://junchat.yyzs120.cn/livekit/jwt")' "production livekit jwt endpoint"
check_file_contains ElementX/Sources/Screens/CallScreen/View/CallScreen.swift 'livekit_service_url: "\(liveKitJWTURL.absoluteString)"' "element call livekit config injection"
check_file_not_contains NSE/SupportingFiles/NSE.entitlements "com.apple.developer.usernotifications.filtering" "no unapproved notification filtering entitlement"
check_file_not_contains NSE/SupportingFiles/target.yml "com.apple.developer.usernotifications.filtering" "no generated notification filtering entitlement"
check_file_contains ElementX/Resources/Assets.xcassets/images/app-logo.imageset/Contents.json '"filename" : "app-logo.svg"' "junchat logo asset"
check_file_contains ElementX/Resources/Assets.xcassets/images/app-logo.imageset/app-logo.svg ">Jun<" "junchat logo text"
check_file_contains ElementX/Sources/Screens/Authentication/StartScreen/AuthenticationStartScreenModels.swift "let shouldAutoLogin: Bool" "internal login view state"
check_file_contains ElementX/Sources/Screens/Authentication/StartScreen/View/AuthenticationStartScreen.swift "triggerInternalLoginIfNeeded()" "auto login on launch"
check_file_not_contains ElementX/Sources/Screens/Authentication/StartScreen/View/AuthenticationStartScreen.swift "authenticationStartScreen.appVersion" "no start screen version"
check_file_not_contains ElementX/Sources/Screens/Authentication/StartScreen/View/AuthenticationStartScreen.swift "developerOptionsButton" "no start screen developer options"
check_file_contains ElementX/Sources/FlowCoordinators/AuthenticationFlowCoordinator.swift "isJunchatInternalLogin" "direct login coordinator mode"
check_file_contains ElementX/Sources/FlowCoordinators/AuthenticationFlowCoordinator.swift "navigationStackCoordinator.setRootCoordinator(coordinator)" "login screen is root"
check_file_contains ElementX/Sources/Screens/Authentication/LoginScreen/View/LoginScreen.swift "AuthenticationStartLogo(size:" "login screen junchat logo"
check_file_not_contains ElementX/Sources/Screens/Authentication/LoginScreen/View/LoginScreen.swift "BigIcon(icon: \\.lockSolid)" "no login lock icon"
check_file_not_contains ElementX/Sources/Screens/Authentication/LoginScreen/View/LoginScreen.swift "screenLoginTitleWithHomeserver" "no homeserver title on login"
check_file_not_contains ElementX/Sources/Screens/Authentication/LoginScreen/View/LoginScreen.swift "screenLoginFormHeader" "no login description header"
check_file_contains ElementX/Sources/Other/Extensions/Bundle.swift "static var junchatPreferredLocalizations" "junchat localization resolver"
check_file_contains ElementX/SupportingFiles/Info.plist "<string>zh-Hans</string>" "simplified chinese localization in info plist"
check_file_contains ElementX/SupportingFiles/Info.plist "<string>zh-Hant-TW</string>" "traditional chinese localization in info plist"
check_file_contains ElementX/SupportingFiles/target.yml "Strip non-Junchat localizations" "strip non-chinese localizations"
check_file_not_contains ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift "settingsVersionNumber" "no settings version number"
check_file_contains ElementX/Resources/Localizations/zh-Hans.lproj/Localizable.strings '"screen_roomlist_main_space_title" = "君聊";' "home screen title"
check_file_contains ElementX/Resources/Localizations/zh-Hans.lproj/Localizable.strings '"screen_home_tab_chats" = "君聊";' "chats tab title"
check_file_contains ElementX/Resources/Localizations/zh-Hans.lproj/Localizable.strings '"screen_signout_preference_item" = "退出登录";' "logout label"
check_file_contains ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift 'title: "娱乐 Tab"' "settings entertainment toggle"
check_file_contains ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift 'title: "君聊支持中心"' "settings support entry"
check_file_contains ElementX/Sources/Screens/Settings/JunchatSupportScreen/View/JunchatSupportScreen.swift '.navigationTitle("君聊支持中心")' "support screen title"
check_file_contains ElementX/Sources/Screens/RoomScreen/ComposerToolbar/ComposerToolbarViewModel.swift "JunchatContentFilter.containsObjectionableContent" "local objectionable content filter"
check_file_contains ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift 'title: "娱乐"' "entertainment tab title"
check_file_contains ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift 'if flowParameters.appSettings.showEntertainmentTab' "entertainment tab gated by setting"
check_file_contains ElementX/Sources/Screens/EntertainmentScreen/JunchatTetrisGame.swift "final class JunchatTetrisGame" "tetris game engine"
check_file_contains ElementX/Sources/Screens/EntertainmentScreen/View/EntertainmentScreen.swift '.navigationTitle("娱乐")' "entertainment screen title"
check_file_not_contains ElementX/Sources/Screens/StartChatScreen/View/StartChatScreen.swift "MatrixUserShareLink" "no start chat invite link"
check_file_not_contains ElementX/Sources/Screens/StartChatScreen/View/StartChatScreen.swift "inviteFriendsSection" "no start chat invite friends section"
check_file_not_contains ElementX/Sources/Screens/StartChatScreen/View/StartChatScreen.swift "JoinRoomByAddressView" "no start chat room address sheet"
check_file_not_contains ElementX/Sources/Screens/StartChatScreen/View/StartChatScreen.swift "screenStartChatJoinRoomByAddressAction" "no start chat room address action"
check_file_not_contains ElementX/Sources/Screens/StartChatScreen/View/StartChatScreen.swift "screenRoomDirectorySearchTitle" "no start chat room directory action"
check_file_not_contains ElementX/Sources/Screens/StartChatScreen/View/StartChatScreen.swift "screenCreateRoomActionCreateRoom" "no start chat create room action"

check_file_contains project.yml "Canary: debug" "canary debug build configuration"
check_file_contains ElementX/SupportingFiles/target.yml "ElementX Canary:" "canary scheme"
check_file_contains ElementX/SupportingFiles/target.yml "Canary: Canary.xcconfig" "app canary xcconfig assignment"
check_file_contains NSE/SupportingFiles/target.yml "Canary: ../../ElementX/SupportingFiles/Canary.xcconfig" "nse canary xcconfig assignment"
check_file_contains ShareExtension/SupportingFiles/target.yml "Canary: ../../ElementX/SupportingFiles/Canary.xcconfig" "share extension canary xcconfig assignment"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig "BASE_BUNDLE_IDENTIFIER = com.heyujk.junchat.canary" "canary bundle identifier"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig "APP_GROUP_IDENTIFIER = group.com.heyujk.junchat.canary" "canary app group"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig "JUNCHAT_URL_SCHEME = matrix-canary" "canary matrix url scheme"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig "JUNCHAT_ASSOCIATED_DOMAIN = canary.junchat.yyzs120.cn" "canary associated domain"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig 'JUNCHAT_OIDC_REDIRECT_URL = https:/$()/canary.junchat.yyzs120.cn/oidc/login' "canary oidc endpoint"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig 'JUNCHAT_PUSH_GATEWAY_BASE_URL = https:/$()/canary.junchat.yyzs120.cn/push' "canary push endpoint"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig 'JUNCHAT_DIAGNOSTICS_ENDPOINT = https:/$()/canary.junchat.yyzs120.cn/diagnostics/api/events' "canary diagnostics endpoint"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig "JUNCHAT_RAGESHAKE_ENABLED = NO" "canary rageshake disabled"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig "JUNCHAT_BACKGROUND_APP_REFRESH_TASK_IDENTIFIER = com.heyujk.junchat.canary.background.refresh" "canary background identifier"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig 'JUNCHAT_LIVEKIT_JWT_URL = https:/$()/canary.junchat.yyzs120.cn/livekit/jwt' "canary livekit endpoint"
check_file_contains ElementX/SupportingFiles/Canary.xcconfig 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) JUNCHAT_CANARY' "canary compilation condition"
check_file_not_contains ElementX/SupportingFiles/Canary.xcconfig "https://" "canary xcconfig has no unescaped URL comments"
check_file_not_contains ElementX/Sources/Services/Environment/JunchatServerEnvironment.swift "update" "no dead update endpoint"
check_file_contains ElementX/Sources/Other/Logging/MXLog.swift "#if JUNCHAT_CANARY" "canary diagnostics compile boundary"
check_file_contains ElementX/Sources/Other/Logging/MXLog.swift "static func install()" "canary diagnostics no-op"
check_file_contains NSE/SupportingFiles/target.yml "Services/Environment/JunchatServerEnvironment.swift" "nse environment source membership"
check_file_contains ShareExtension/SupportingFiles/target.yml "Services/Environment/JunchatServerEnvironment.swift" "share extension environment source membership"

for plist in ElementX/SupportingFiles/Info.plist NSE/SupportingFiles/Info.plist ShareExtension/SupportingFiles/Info.plist; do
    check_file_contains "$plist" "JunchatMatrixAccountProvider" "matrix environment key in $plist"
    check_file_contains "$plist" "JunchatOIDCRedirectURL" "oidc environment key in $plist"
    check_file_contains "$plist" "JunchatPushGatewayBaseURL" "push environment key in $plist"
    check_file_contains "$plist" "JunchatDiagnosticsEndpoint" "diagnostics environment key in $plist"
    check_file_contains "$plist" "JunchatRageshakeEnabled" "rageshake environment key in $plist"
    check_file_contains "$plist" "JunchatBackgroundAppRefreshTaskIdentifier" "background environment key in $plist"
    check_file_contains "$plist" "JunchatLiveKitJWTURL" "livekit environment key in $plist"
done

if [[ ! -f ElementX/Resources/Sounds/junchat-message.caf ]]; then
    printf 'not ok - message sound file\n  missing: ElementX/Resources/Sounds/junchat-message.caf\n' >&2
    failures=$((failures + 1))
else
    printf 'ok - message sound file\n'
fi

if [[ ! -f ElementX/Resources/Sounds/junchat-call.caf ]]; then
    printf 'not ok - call sound file\n  missing: ElementX/Resources/Sounds/junchat-call.caf\n' >&2
    failures=$((failures + 1))
else
    printf 'ok - call sound file\n'
fi

check_audio_duration_between ElementX/Resources/Sounds/junchat-call.caf 25.0 29.9 "call ringtone duration"

if [[ "$failures" -ne 0 ]]; then
    printf '\n%d Junchat iOS configuration checks failed.\n' "$failures" >&2
    exit 1
fi

printf '\nAll Junchat iOS configuration checks passed.\n'
