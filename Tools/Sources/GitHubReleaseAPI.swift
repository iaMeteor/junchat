import Foundation

struct GitHubReleaseAPI {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    enum APIError: LocalizedError {
        case invalidResponse
        case failedRequest(statusCode: Int, message: String)
        case incompatibleExistingRelease
        case incompatibleExistingPreparation
        case missingExistingDraft
        case duplicateExistingRelease
        case releaseSearchLimitExceeded

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "GitHub returned an invalid release response."
            case .failedRequest(let statusCode, let message):
                "GitHub release request failed with HTTP \(statusCode): \(message)"
            case .incompatibleExistingRelease:
                "An existing GitHub release does not match the requested draft and archived commit."
            case .incompatibleExistingPreparation:
                "The remote branch does not contain the exact expected release preparation commit."
            case .missingExistingDraft:
                "Remote release preparation validation requires an existing compatible draft."
            case .duplicateExistingRelease:
                "GitHub returned multiple releases for the requested tag."
            case .releaseSearchLimitExceeded:
                "GitHub release lookup exceeded the bounded pagination limit."
            }
        }
    }

    private static let pageSize = 100
    private static let maximumPages = 100
    private static let maximumTagDepth = 10
    private static let apiVersion = "2026-03-10"

    private let dataLoader: DataLoader

    init(dataLoader: @escaping DataLoader = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.dataLoader = dataLoader
    }

    func createOrReuseDraft(version: String,
                            targetCommit: String,
                            repository: GitHubRepository,
                            token: String,
                            allowCreation: Bool = true) async throws -> String {
        let releaseRequest = GitHubReleaseRequest(version: version, targetCommit: targetCommit)
        if let body = try await reusableDraftBody(for: releaseRequest,
                                                  repository: repository,
                                                  token: token) {
            return body
        }
        guard allowCreation else {
            throw APIError.missingExistingDraft
        }

        do {
            return try await createDraft(releaseRequest,
                                         repository: repository,
                                         token: token)
        } catch APIError.failedRequest(statusCode: 422, message: _) {
            // A concurrent retry may have created the same draft after lookup.
            if let body = try await reusableDraftBody(for: releaseRequest,
                                                      repository: repository,
                                                      token: token) {
                return body
            }
            throw APIError.failedRequest(statusCode: 422,
                                         message: "The release could not be created and no compatible draft exists.")
        }
    }

    func isPreparationAlreadyPushed(branch: String,
                                    releaseVersion: JunchatReleaseVersion,
                                    releaseCommit: String,
                                    generatedNotes: String,
                                    repository: GitHubRepository,
                                    token: String) async throws -> Bool {
        let remoteCommit = try await remoteBranchCommit(branch: branch,
                                                        repository: repository,
                                                        token: token)
        guard remoteCommit != releaseCommit else { return false }

        let commitURL = try repositoryAPIURL(repository: repository,
                                             pathComponents: ["commits", remoteCommit])
        let commitData = try await successfulData(for: authenticatedRequest(url: commitURL, token: token))
        let commit = try JSONDecoder().decode(GitHubCommitRecord.self, from: commitData)
        guard commit.sha == remoteCommit,
              commit.files.count == JunchatReleasePreparation.expectedChangedPaths.count,
              Set(commit.files.map(\.filename)) == JunchatReleasePreparation.expectedChangedPaths,
              commit.files.allSatisfy({ $0.status == "modified" }),
              let preparation = try JunchatReleasePreparation.parseIfPresent(commit.commit.message),
              preparation.releaseVersion == releaseVersion,
              preparation.releaseCommit == releaseCommit else {
            throw APIError.incompatibleExistingPreparation
        }

        let changedFiles = try await repositoryChangedFiles(tree: commit.commit.tree.sha,
                                                            repository: repository,
                                                            token: token)
        guard changedFiles.count == JunchatReleasePreparation.expectedChangedFiles.count,
              Set(changedFiles) == JunchatReleasePreparation.expectedChangedFiles else {
            throw APIError.incompatibleExistingPreparation
        }

        // Rebuild every allowlisted file from the archived parent so a matching marker cannot bless unrelated edits.
        let releaseProject = try await repositoryContent(path: JunchatReleasePreparation.projectYAMLPath,
                                                         commit: releaseCommit,
                                                         repository: repository,
                                                         token: token)
        let preparedProject = try await repositoryContent(path: JunchatReleasePreparation.projectYAMLPath,
                                                          commit: commit.sha,
                                                          repository: repository,
                                                          token: token)
        let expectedProject = try preparation.expectedProjectYAML(releaseProject)
        guard preparedProject == expectedProject else {
            throw APIError.incompatibleExistingPreparation
        }

        try preparation.validateResume(parentCommits: commit.parents.map(\.sha),
                                       currentVersion: JunchatReleaseVersion.parse(preparedProject),
                                       changedFiles: changedFiles)

        let releaseChangelog = try await repositoryContent(path: JunchatReleasePreparation.changelogPath,
                                                           commit: releaseCommit,
                                                           repository: repository,
                                                           token: token)
        let preparedChangelog = try await repositoryContent(path: JunchatReleasePreparation.changelogPath,
                                                            commit: commit.sha,
                                                            repository: repository,
                                                            token: token)
        let expectedChangelog = try preparation.expectedChangelog(releaseChangelog,
                                                                  generatedNotes: generatedNotes)
        guard preparedChangelog == expectedChangelog else {
            throw APIError.incompatibleExistingPreparation
        }

        let releaseXcodeProject = try await repositoryContent(path: JunchatReleasePreparation.xcodeProjectPath,
                                                              commit: releaseCommit,
                                                              repository: repository,
                                                              token: token)
        let preparedXcodeProject = try await repositoryContent(path: JunchatReleasePreparation.xcodeProjectPath,
                                                               commit: commit.sha,
                                                               repository: repository,
                                                               token: token)
        let expectedXcodeProject = try preparation.expectedXcodeProject(releaseXcodeProject)
        guard preparedXcodeProject == expectedXcodeProject else {
            throw APIError.incompatibleExistingPreparation
        }
        return true
    }

    func remoteBranchCommit(branch: String,
                            repository: GitHubRepository,
                            token: String) async throws -> String {
        let branchComponents = branch.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !branchComponents.isEmpty, branchComponents.allSatisfy({ !$0.isEmpty }) else {
            throw APIError.invalidResponse
        }
        let referenceURL = try repositoryAPIURL(repository: repository,
                                                pathComponents: ["git", "ref", "heads"] + branchComponents)
        let referenceData = try await successfulData(for: authenticatedRequest(url: referenceURL, token: token))
        let object = try JSONDecoder().decode(GitHubReferenceRecord.self, from: referenceData).object
        guard object.type == "commit" else {
            throw APIError.invalidResponse
        }
        return object.sha
    }

    private func reusableDraftBody(for releaseRequest: GitHubReleaseRequest,
                                   repository: GitHubRepository,
                                   token: String) async throws -> String? {
        for page in 1...Self.maximumPages {
            let releases = try await listReleases(repository: repository,
                                                  token: token,
                                                  page: page)
            let matchingReleases = releases.filter { $0.tagName == releaseRequest.tagName }
            guard matchingReleases.count <= 1 else {
                throw APIError.duplicateExistingRelease
            }
            if let release = matchingReleases.first {
                let body = try release.validatedDraftBody(for: releaseRequest,
                                                          validateTargetCommitish: false)
                let tagCommit = try await releaseTagCommit(tagName: releaseRequest.tagName,
                                                           repository: repository,
                                                           token: token)
                guard tagCommit == releaseRequest.targetCommit else {
                    throw APIError.incompatibleExistingRelease
                }
                return body
            }
            if releases.count < Self.pageSize {
                return nil
            }
        }
        throw APIError.releaseSearchLimitExceeded
    }

    private func listReleases(repository: GitHubRepository,
                              token: String,
                              page: Int) async throws -> [GitHubReleaseRecord] {
        guard var components = URLComponents(url: repository.releasesAPIURL,
                                             resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "per_page", value: String(Self.pageSize)),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else {
            throw APIError.invalidResponse
        }
        let request = authenticatedRequest(url: url, token: token)
        let data = try await successfulData(for: request)
        return try JSONDecoder().decode([GitHubReleaseRecord].self, from: data)
    }

    private func createDraft(_ releaseRequest: GitHubReleaseRequest,
                             repository: GitHubRepository,
                             token: String) async throws -> String {
        var request = authenticatedRequest(url: repository.releasesAPIURL, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(releaseRequest)
        let data = try await successfulData(for: request)
        let release = try JSONDecoder().decode(GitHubReleaseRecord.self, from: data)
        return try release.validatedDraftBody(for: releaseRequest,
                                              validateTargetCommitish: true)
    }

    private func releaseTagCommit(tagName: String,
                                  repository: GitHubRepository,
                                  token: String) async throws -> String {
        let tagComponents = tagName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !tagComponents.isEmpty, tagComponents.allSatisfy({ !$0.isEmpty }) else {
            throw APIError.invalidResponse
        }

        let referenceURL = try repositoryAPIURL(repository: repository,
                                                pathComponents: ["git", "ref", "tags"] + tagComponents)
        let referenceData = try await successfulData(for: authenticatedRequest(url: referenceURL, token: token))
        var object = try JSONDecoder().decode(GitHubReferenceRecord.self, from: referenceData).object
        var visitedTags = Set<String>()

        for _ in 0..<Self.maximumTagDepth {
            switch object.type {
            case "commit":
                return object.sha
            case "tag":
                guard visitedTags.insert(object.sha).inserted else {
                    throw APIError.incompatibleExistingRelease
                }
                let tagURL = try repositoryAPIURL(repository: repository,
                                                  pathComponents: ["git", "tags", object.sha])
                let tagData = try await successfulData(for: authenticatedRequest(url: tagURL, token: token))
                object = try JSONDecoder().decode(GitHubTagRecord.self, from: tagData).object
            default:
                throw APIError.incompatibleExistingRelease
            }
        }
        throw APIError.incompatibleExistingRelease
    }

    private func repositoryChangedFiles(tree: String,
                                        repository: GitHubRepository,
                                        token: String) async throws -> [JunchatReleasePreparation.ChangedFile] {
        let treeURL = try repositoryAPIURL(repository: repository,
                                           pathComponents: ["git", "trees", tree],
                                           queryItems: [URLQueryItem(name: "recursive", value: "1")])
        let data = try await successfulData(for: authenticatedRequest(url: treeURL, token: token))
        let record = try JSONDecoder().decode(GitHubTreeRecord.self, from: data)
        guard !record.truncated else {
            throw APIError.incompatibleExistingPreparation
        }

        return try record.tree.compactMap { entry in
            guard JunchatReleasePreparation.expectedChangedPaths.contains(entry.path) else { return nil }
            guard entry.type == "blob" else {
                throw APIError.incompatibleExistingPreparation
            }
            return JunchatReleasePreparation.ChangedFile(path: entry.path, mode: entry.mode)
        }
    }

    private func repositoryContent(path: String,
                                   commit: String,
                                   repository: GitHubRepository,
                                   token: String) async throws -> String {
        let contentPath = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !contentPath.isEmpty, contentPath.allSatisfy({ !$0.isEmpty }) else {
            throw APIError.invalidResponse
        }
        let url = try repositoryAPIURL(repository: repository,
                                       pathComponents: ["contents"] + contentPath,
                                       queryItems: [URLQueryItem(name: "ref", value: commit)])
        let data = try await successfulData(for: authenticatedRequest(url: url, token: token))
        return try JSONDecoder().decode(GitHubContentRecord.self, from: data).decodedContent()
    }

    private func repositoryAPIURL(repository: GitHubRepository,
                                  pathComponents: [String],
                                  queryItems: [URLQueryItem] = []) throws -> URL {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let components = ["repos", repository.owner, repository.name] + pathComponents
        let encodedComponents = try components.map { component -> String in
            guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
                throw APIError.invalidResponse
            }
            return encoded
        }
        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = "api.github.com"
        urlComponents.percentEncodedPath = "/" + encodedComponents.joined(separator: "/")
        urlComponents.queryItems = queryItems
        guard let url = urlComponents.url else {
            throw APIError.invalidResponse
        }
        return url
    }

    private func authenticatedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("JunChat-iOS-Release-Tool", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func successfulData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await dataLoader(request)
        guard let response = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .prefix(2000)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw APIError.failedRequest(statusCode: response.statusCode,
                                         message: message)
        }
        return data
    }
}

private struct GitHubReleaseRecord: Decodable {
    let tagName: String
    let name: String?
    let targetCommitish: String
    let body: String?
    let draft: Bool
    let prerelease: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case targetCommitish = "target_commitish"
        case body
        case draft
        case prerelease
    }

    func validatedDraftBody(for request: GitHubReleaseRequest,
                            validateTargetCommitish: Bool) throws -> String {
        guard draft,
              !prerelease,
              tagName == request.tagName,
              name == request.name,
              !validateTargetCommitish || targetCommitish == request.targetCommit,
              let body else {
            throw GitHubReleaseAPI.APIError.incompatibleExistingRelease
        }
        return body
    }
}

private struct GitHubReferenceRecord: Decodable {
    let object: GitHubObjectPointer
}

private struct GitHubObjectPointer: Decodable {
    let sha: String
    let type: String
}

private struct GitHubCommitPointer: Decodable {
    let sha: String
}

private struct GitHubTagRecord: Decodable {
    let object: GitHubObjectPointer
}

private struct GitHubCommitRecord: Decodable {
    struct Commit: Decodable {
        let message: String
        let tree: GitHubCommitPointer
    }

    struct File: Decodable {
        let filename: String
        let status: String
    }

    let sha: String
    let commit: Commit
    let parents: [GitHubCommitPointer]
    let files: [File]
}

private struct GitHubTreeRecord: Decodable {
    struct Entry: Decodable {
        let path: String
        let mode: String
        let type: String
    }

    let tree: [Entry]
    let truncated: Bool
}

private struct GitHubContentRecord: Decodable {
    let encoding: String
    let content: String

    func decodedContent() throws -> String {
        guard encoding == "base64",
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
              let value = String(data: data, encoding: .utf8) else {
            throw GitHubReleaseAPI.APIError.invalidResponse
        }
        return value
    }
}
