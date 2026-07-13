import Foundation
@testable import Tools
import XCTest

final class GitHubReleaseRequestTests: XCTestCase {
    func testCreatesAnApprovalGatedDraftForTheArchivedCommit() throws {
        let request = GitHubReleaseRequest(version: "1.8.2",
                                           targetCommit: String(repeating: "a", count: 40))
        let data = try JSONEncoder().encode(request)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["tag_name"] as? String, "release/1.8.2")
        XCTAssertEqual(payload["name"] as? String, "1.8.2")
        XCTAssertEqual(payload["target_commitish"] as? String, String(repeating: "a", count: 40))
        XCTAssertEqual(payload["generate_release_notes"] as? Bool, true)
        XCTAssertEqual(payload["draft"] as? Bool, true)
    }
}
