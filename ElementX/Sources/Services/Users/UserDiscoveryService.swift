//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

final class UserDiscoveryService: UserDiscoveryServiceProtocol {
    private static let fallbackHomeserver = "junchat.yyzs120.cn"
    
    private let clientProxy: ClientProxyProtocol
    private let localHomeserver: String
    
    init(clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
        localHomeserver = Self.homeserver(from: clientProxy.userID) ?? Self.fallbackHomeserver
    }

    func searchProfiles(with searchQuery: String) async -> Result<[UserProfileProxy], UserDiscoveryErrorType> {
        let trimmedSearchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        async let queriedProfile = profileIfPossible(with: trimmedSearchQuery)

        do {
            async let searchedUsers = clientProxy.searchUsers(searchTerm: trimmedSearchQuery, limit: 10).get()
            let users = try await merge(queriedProfile: queriedProfile, searchResults: searchedUsers)
            return .success(filterAccountOwner(filterLocalHomeserver(users)))
        } catch {
            // we want to show the profile (if any) even if the search fails
            if let queriedProfile = await queriedProfile {
                return .success([queriedProfile])
            } else {
                return .failure(.failedSearchingUsers)
            }
        }
    }

    private func merge(queriedProfile: UserProfileProxy?, searchResults: SearchUsersResultsProxy) -> [UserProfileProxy] {
        let searchResults = searchResults.results
        
        guard let queriedProfile else {
            return searchResults
        }

        let filteredSearchResult = searchResults.filter {
            $0.userID != queriedProfile.userID
        }

        return [queriedProfile] + filteredSearchResult
    }
    
    private func profileIfPossible(with searchQuery: String) async -> UserProfileProxy? {
        guard let userID = localUserID(from: searchQuery),
              userID != clientProxy.userID else {
            return nil
        }
        
        let getProfileResult = try? await clientProxy.profile(for: userID).get()
        
        // fallback to a "local profile" if the profile api fails
        return getProfileResult ?? .init(userID: userID)
    }

    private func filterAccountOwner(_ profiles: [UserProfileProxy]) -> [UserProfileProxy] {
        let accountOwnerID = clientProxy.userID
        return profiles.filter { $0.userID != accountOwnerID }
    }
    
    private func filterLocalHomeserver(_ profiles: [UserProfileProxy]) -> [UserProfileProxy] {
        profiles.filter { isLocalUserID($0.userID) }
    }
    
    private func localUserID(from searchQuery: String) -> String? {
        guard !searchQuery.isEmpty else {
            return nil
        }
        
        if searchQuery.isMatrixIdentifier {
            return isLocalUserID(searchQuery) ? searchQuery : nil
        }
        
        let localpart: String
        if searchQuery.hasPrefix("@") {
            localpart = String(searchQuery.dropFirst())
        } else if let homeserver = Self.homeserver(from: "@\(searchQuery)"),
                  homeserver.caseInsensitiveCompare(localHomeserver) == .orderedSame {
            localpart = String(searchQuery.prefix(searchQuery.count - homeserver.count - 1))
        } else {
            localpart = searchQuery
        }
        
        guard !localpart.isEmpty, !localpart.contains(":") else {
            return nil
        }
        
        let candidate = "@\(localpart.lowercased()):\(localHomeserver)"
        return candidate.isMatrixIdentifier ? candidate : nil
    }
    
    private func isLocalUserID(_ userID: String) -> Bool {
        guard userID.isMatrixIdentifier,
              let homeserver = Self.homeserver(from: userID) else {
            return false
        }
        
        return homeserver.caseInsensitiveCompare(localHomeserver) == .orderedSame
    }
    
    private static func homeserver(from userID: String) -> String? {
        guard let separatorIndex = userID.lastIndex(of: ":"),
              separatorIndex < userID.index(before: userID.endIndex) else {
            return nil
        }
        
        return String(userID[userID.index(after: separatorIndex)...])
    }
}

private extension String {
    var isMatrixIdentifier: Bool {
        MatrixEntityRegex.isMatrixUserIdentifier(self)
    }
}
