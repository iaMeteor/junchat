import Foundation

struct GitHubReleaseRequest: Encodable, Equatable {
    let tagName: String
    let name: String
    let targetCommit: String
    let generateReleaseNotes = true
    let draft = true
    let prerelease = false

    init(version: String, targetCommit: String) {
        tagName = "release/\(version)"
        name = version
        self.targetCommit = targetCommit
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case targetCommit = "target_commitish"
        case generateReleaseNotes = "generate_release_notes"
        case draft
        case prerelease
    }
}
