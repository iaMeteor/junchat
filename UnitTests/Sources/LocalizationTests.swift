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
    }
}
