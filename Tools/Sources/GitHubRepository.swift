import Foundation

struct GitHubRepository: Equatable {
    enum RepositoryError: LocalizedError {
        case unsupportedRemote

        var errorDescription: String? {
            "Origin must identify exactly one github.com owner and repository"
        }
    }

    let owner: String
    let name: String

    var slug: String {
        "\(owner)/\(name)"
    }

    var httpsURL: URL {
        URL(string: "https://github.com/\(slug).git")!
    }

    var releasesAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(slug)/releases")!
    }

    init(remoteURL rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryPath: String

        if value.hasPrefix("git@github.com:") {
            repositoryPath = String(value.dropFirst("git@github.com:".count))
        } else {
            guard let url = URL(string: value),
                  url.host?.lowercased() == "github.com",
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ssh"].contains(scheme),
                  url.port == nil,
                  url.query == nil,
                  url.fragment == nil,
                  url.password == nil,
                  scheme == "ssh" ? url.user == "git" : url.user == nil else {
                throw RepositoryError.unsupportedRemote
            }
            repositoryPath = url.path
        }

        var components = repositoryPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count == 2 else {
            throw RepositoryError.unsupportedRemote
        }
        if components[1].hasSuffix(".git") {
            components[1].removeLast(4)
        }
        guard components.allSatisfy(Self.isValidComponent) else {
            throw RepositoryError.unsupportedRemote
        }

        owner = components[0]
        name = components[1]
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
        }
    }
}
