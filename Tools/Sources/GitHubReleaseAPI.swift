import Foundation

struct GitHubReleaseAPI {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    enum APIError: LocalizedError {
        case invalidResponse
        case failedRequest(statusCode: Int, message: String)
        case incompatibleExistingRelease
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
            case .duplicateExistingRelease:
                "GitHub returned multiple releases for the requested tag."
            case .releaseSearchLimitExceeded:
                "GitHub release lookup exceeded the bounded pagination limit."
            }
        }
    }

    private static let pageSize = 100
    private static let maximumPages = 100
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
                            token: String) async throws -> String {
        let releaseRequest = GitHubReleaseRequest(version: version, targetCommit: targetCommit)
        if let body = try await reusableDraftBody(for: releaseRequest,
                                                  repository: repository,
                                                  token: token) {
            return body
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
                return try release.validatedDraftBody(for: releaseRequest)
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
        return try release.validatedDraftBody(for: releaseRequest)
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

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case targetCommitish = "target_commitish"
        case body
        case draft
    }

    func validatedDraftBody(for request: GitHubReleaseRequest) throws -> String {
        guard draft,
              tagName == request.tagName,
              name == request.name,
              targetCommitish == request.targetCommit,
              let body else {
            throw GitHubReleaseAPI.APIError.incompatibleExistingRelease
        }
        return body
    }
}
