import Foundation
@testable import Tools
import XCTest

final class JunchatReleaseNotesTests: XCTestCase {
    func testKeepsJunchatNotesSeparateFromUpstreamHistory() throws {
        let existing = "# JunChat iOS Changes\n\n" +
            "JunChat fork release notes are recorded here. Upstream history remains in `CHANGES.md`."
        let generated = """
        <!-- generated metadata -->
        ## Highlights
        - Fixed call routing
        ### Contributors
        - Example
        """

        let updated = try JunchatReleaseNotes.updatedChangelog(existingContent: existing,
                                                               version: "1.8.2",
                                                               generatedNotes: generated,
                                                               releaseDate: "2026-07-13")

        XCTAssertTrue(updated.hasPrefix("# JunChat iOS Changes\n\n## Changes in 1.8.2 (2026-07-13)"))
        XCTAssertTrue(updated.contains("### Highlights\n- Fixed call routing"))
        XCTAssertTrue(updated.contains("#### Contributors\n- Example"))
        XCTAssertFalse(updated.contains("generated metadata"))
        XCTAssertTrue(updated.contains("Upstream history remains in `CHANGES.md`."))
    }

    func testRejectsEmptyOrMalformedReleaseInputs() throws {
        XCTAssertThrowsError(try JunchatReleaseNotes.updatedChangelog(existingContent: "# Wrong heading\n",
                                                                      version: "1.8.2",
                                                                      generatedNotes: "- Fix\n",
                                                                      releaseDate: "2026-07-13"))
        XCTAssertThrowsError(try JunchatReleaseNotes.updatedChangelog(existingContent: "# JunChat iOS Changes\n",
                                                                      version: "1.8.2",
                                                                      generatedNotes: "<!-- only a comment -->",
                                                                      releaseDate: "2026-07-13"))
    }
}
