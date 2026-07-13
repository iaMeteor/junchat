//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct ContactsService: ContactsServiceProtocol {
    private let clientProxy: ClientProxyProtocol
    
    init(clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
    }
    
    func contacts() async -> Result<[UserProfileProxy], ContactsServiceError> {
        switch await clientProxy.junchatContacts() {
        case .success(let contacts):
            let filteredContacts = contacts
                .filter { $0.userID != clientProxy.userID }
                .sorted(by: Self.sortContacts)
            
            return .success(filteredContacts)
        case .failure:
            return .failure(.failedFetchingContacts)
        }
    }
    
    private static func sortContacts(_ lhs: UserProfileProxy, _ rhs: UserProfileProxy) -> Bool {
        let lhsKey = sortKey(for: lhs)
        let rhsKey = sortKey(for: rhs)
        let comparison = lhsKey.localizedCaseInsensitiveCompare(rhsKey)
        
        if comparison == .orderedSame {
            return lhs.userID.localizedCaseInsensitiveCompare(rhs.userID) == .orderedAscending
        }
        
        return comparison == .orderedAscending
    }
    
    private static func sortKey(for profile: UserProfileProxy) -> String {
        if let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        
        return localpart(from: profile.userID)
    }
    
    private static func localpart(from userID: String) -> String {
        userID
            .trimmingPrefix("@")
            .split(separator: ":", maxSplits: 1)
            .first
            .map(String.init) ?? userID
    }
}

struct JunchatContact: Decodable {
    let userID: String
    let displayName: String?
    let avatarURL: URL?
    
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

extension UserProfileProxy {
    init(junchatContact: JunchatContact) {
        self.init(userID: junchatContact.userID,
                  displayName: junchatContact.displayName,
                  avatarURL: junchatContact.avatarURL)
    }
}
