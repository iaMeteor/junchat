//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

final class LocalizationTests {
    deinit {
        Bundle.overrideLocalizations = nil
    }
    
    /// Test Junchat only follows Simplified and Traditional Chinese.
    @Test
    func appLanguage() {
        Bundle.overrideLocalizations = ["en"]
        
        #expect(L10n.testLanguageIdentifier == "zh-Hans")
        
        Bundle.overrideLocalizations = ["zh-Hant"]
        
        #expect(L10n.testLanguageIdentifier == "zh-tw")
    }
    
    /// Test fallback language for a language not supported at all
    @Test
    func fallbackOnNotSupportedLanguage() {
        //  set app language to something Element don't support at all (chose non existing identifier)
        Bundle.overrideLocalizations = ["xx"]
        
        #expect(L10n.testLanguageIdentifier == "zh-Hans")
    }
    
    /// Test fallback language for a language supported but poorly translated
    @Test
    func fallbackOnNotTranslatedKey() {
        //  set app language to something Element supports but use a key that is not translated (we have a key that should never be translated)
        Bundle.overrideLocalizations = ["en"]
        
        #expect(L10n.testLanguageIdentifier == "zh-Hans")
        #expect(L10n.testUntranslatedDefaultLanguageIdentifier == "zh-Hans")
    }
    
    /// Test plurals that ElementL10n considers app language changes
    @Test
    func plurals() {
        Bundle.overrideLocalizations = ["zh-Hans"]
        
        #expect(L10n.commonMemberCount(1) == "1 个成员")
        #expect(L10n.commonMemberCount(2) == "2 个成员")
        
        Bundle.overrideLocalizations = ["zh-Hant"]
        
        #expect(L10n.commonMemberCount(1) == "1 位成員")
        #expect(L10n.commonMemberCount(2) == "2 位成員")
    }
    
    /// Test plurals fallback language for a language not supported at all
    @Test
    func pluralsFallbackOnNotSupportedLanguage() {
        //  set app language to something Element don't support at all ("invalid identifier")
        Bundle.overrideLocalizations = ["xx"]
        
        #expect(L10n.commonMemberCount(1) == "1 个成员")
        #expect(L10n.commonMemberCount(2) == "2 个成员")
    }
    
    /// Test untranslated strings
    @Test
    func untranslated() {
        #expect(UntranslatedL10n.untranslated == "未翻译")
        #expect(UntranslatedL10n.untranslatedPlural(1) == "1 个未翻译项目")
        #expect(UntranslatedL10n.untranslatedPlural(5) == "5 个未翻译项目")
        #expect(UntranslatedL10n.screenMessageForwardingProgressAccessibilityValue(2, 3) == "第 2 个，共 3 个")
    }

    @Test
    func messageSelectionStringsExistInEverySupportedResource() throws {
        #expect(try untranslatedString("action_select_messages", language: "en") == "Select messages")
        #expect(try untranslatedString("screen_message_forwarding_capacity_exceeded", language: "en") ==
            "No more messages can be forwarded safely because too many unresolved forwards are saved. Check earlier destinations and resolve an uncertain forward before trying again.")
        #expect(try untranslatedString("screen_room_message_selection_delete_confirmation_title", language: "en") == "Delete messages?")

        #expect(try untranslatedString("action_select_messages", language: "zh-Hans") == "多选消息")
        #expect(try untranslatedString("screen_message_forwarding_capacity_exceeded", language: "zh-Hans") == "无法继续安全转发，因为已保存的未确认转发过多。请先检查之前的目标聊天室并处理结果未知的转发。")
        #expect(try untranslatedString("screen_room_message_selection_delete_confirmation_title", language: "zh-Hans") == "删除消息？")

        #expect(try untranslatedString("action_select_messages", language: "zh-Hant-TW") == "多選訊息")
        #expect(try untranslatedString("screen_message_forwarding_capacity_exceeded", language: "zh-Hant-TW") == "無法繼續安全轉傳，因為已儲存的未確認轉傳過多。請先檢查之前的目標聊天室並處理結果未知的轉傳。")
        #expect(try untranslatedString("screen_room_message_selection_delete_confirmation_title", language: "zh-Hant-TW") == "刪除訊息？")
    }

    @Test
    func messageForwardingProgressAccessibilityFormatExistsInEverySupportedResource() throws {
        #expect(try untranslatedString("screen_message_forwarding_progress_accessibility_value", language: "en") == "%1$d of %2$d")
        #expect(try untranslatedString("screen_message_forwarding_progress_accessibility_value", language: "zh-Hans") == "第 %1$d 个，共 %2$d 个")
        #expect(try untranslatedString("screen_message_forwarding_progress_accessibility_value", language: "zh-Hant-TW") == "第 %1$d 個，共 %2$d 個")
    }

    @Test
    func messageSelectionStringsUsePluralRules() throws {
        #expect(try untranslatedString("screen_room_message_selection_selected_count", language: "en", count: 1) == "1 message selected")
        #expect(try untranslatedString("screen_room_message_selection_selected_count", language: "en", count: 3) == "3 messages selected")
        #expect(try untranslatedString("screen_room_message_selection_delete_confirmation", language: "en", count: 1) == "Delete the selected message? Room members will no longer see its original content.")
        #expect(try untranslatedString("screen_room_message_selection_delete_confirmation", language: "en", count: 3) == "Delete the 3 selected messages? Room members will no longer see their original content.")

        #expect(try untranslatedString("screen_room_message_selection_selected_count", language: "zh-Hans", count: 3) == "已选 3 条消息")
        #expect(try untranslatedString("screen_room_message_selection_delete_confirmation", language: "zh-Hans", count: 3) == "要删除选中的 3 条消息吗？删除后聊天室成员都将看不到原内容。")
        #expect(try untranslatedString("screen_room_message_selection_selected_count", language: "zh-Hant-TW", count: 3) == "已選取 3 則訊息")
        #expect(try untranslatedString("screen_room_message_selection_delete_confirmation", language: "zh-Hant-TW", count: 3) == "要刪除選取的 3 則訊息嗎？刪除後聊天室成員都將看不到原始內容。")
    }

    private func untranslatedString(_ key: String, language: String, count: Int? = nil) throws -> String {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localizationURL = repositoryURL
            .appending(path: "ElementX/Resources/Localizations/\(language).lproj", directoryHint: .isDirectory)
        let bundle = try #require(Bundle(url: localizationURL))
        let format = NSLocalizedString(key, tableName: "Untranslated", bundle: bundle, comment: "")
        guard let count else { return format }
        return String(format: format, locale: Locale(identifier: language), count)
    }
}
