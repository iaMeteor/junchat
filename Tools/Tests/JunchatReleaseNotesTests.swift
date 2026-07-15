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

        XCTAssertTrue(updated.hasPrefix("# JunChat iOS Changes\n\nJunChat fork release notes"))
        XCTAssertLessThan(try XCTUnwrap(updated.range(of: "JunChat fork release notes")?.lowerBound),
                          try XCTUnwrap(updated.range(of: "## Changes in 1.8.2")?.lowerBound))
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
        XCTAssertThrowsError(try JunchatReleaseNotes.updatedChangelog(existingContent: "# JunChat iOS Changes\n",
                                                                      version: "1.8.2",
                                                                      generatedNotes: "- Fix\n",
                                                                      releaseDate: "2026-02-30"))
    }

    func testExactRepeatIsIdempotentAndConflictingRepeatFails() throws {
        let existing = "# JunChat iOS Changes\n\n" +
            "JunChat fork release notes are recorded here. Upstream history remains in `CHANGES.md`."
        let first = try JunchatReleaseNotes.updatedChangelog(existingContent: existing,
                                                             version: "1.8.2",
                                                             generatedNotes: "## Highlights\n- Fixed call routing",
                                                             releaseDate: "2026-07-13")

        XCTAssertEqual(try JunchatReleaseNotes.updatedChangelog(existingContent: first,
                                                                version: "1.8.2",
                                                                generatedNotes: "## Highlights\n- Fixed call routing",
                                                                releaseDate: "2026-07-13"),
                       first)
        XCTAssertThrowsError(try JunchatReleaseNotes.updatedChangelog(existingContent: first,
                                                                      version: "1.8.2",
                                                                      generatedNotes: "## Highlights\n- Different notes",
                                                                      releaseDate: "2026-07-13"))
    }

    func testAtomicChangelogReplacementPreservesTheExactMode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changelogURL = directory.appending(path: "JUNCHAT_CHANGES.md")
        try "# JunChat iOS Changes\n".write(to: changelogURL, atomically: false, encoding: .utf8)
        let expectedMode = 0o751
        try FileManager.default.setAttributes([.posixPermissions: expectedMode], ofItemAtPath: changelogURL.path)

        XCTAssertTrue(try JunchatReleaseNotes.updateChangelogFile(at: changelogURL,
                                                                  version: "1.8.2",
                                                                  generatedNotes: "- Fixed retry",
                                                                  releaseDate: "2026-07-16"))

        let attributes = try FileManager.default.attributesOfItem(atPath: changelogURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expectedMode)
    }
}
