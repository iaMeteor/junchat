//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct UserDiscoveryServiceTest {
    private var service: UserDiscoveryService
    private var clientProxy: ClientProxyMock
    
    private var searchResults: [UserProfileProxy] {
        [.mockAlice, .mockBob, .mockCharlie]
    }
    
    init() {
        clientProxy = .init(.init(userID: "@foo:matrix.org"))
        service = UserDiscoveryService(clientProxy: clientProxy)
    }
    
    @Test
    func queryShowingResults() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [UserProfileProxy.mockAlice], limited: true))
        
        let results = await (try? search(query: "Alice Smith").get()) ?? []
        assertSearchResults(results, toBe: 1)
    }
    
    @Test
    func ownerIsFiltered() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [UserProfileProxy(userID: "@foo:matrix.org")], limited: true))
        
        let results = await (try? search(query: "Alice Smith").get()) ?? []
        assertSearchResults(results, toBe: 0)
    }
    
    @Test
    func getProfileIsNotCalled() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@alice:matrix.org"))
        
        let results = await (try? search(query: "Alice Smith").get()) ?? []
        assertSearchResults(results, toBe: 3)
        #expect(!clientProxy.profileForCalled)
    }

    @Test
    func getProfileIsNotCalledForAccountOwnerID() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@alice:matrix.org"))
        
        let results = await (try? search(query: "foo:matrix.org").get()) ?? []
        assertSearchResults(results, toBe: 3)
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func localResultShows() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        let results = await (try? search(query: "@a:matrix.org").get()) ?? []
        
        assertSearchResults(results, toBe: 4)
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func localResultShowsOnSearchError() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        let results = await (try? search(query: "@a:matrix.org").get()) ?? []
        
        assertSearchResults(results, toBe: 1)
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func searchErrorTriggers() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        switch await search(query: "some query") {
        case .success:
            Issue.record("Search users must fail")
        case .failure(let error):
            #expect(error == UserDiscoveryErrorType.failedSearchingUsers)
        }
        
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func localResultWithDuplicates() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@bob:matrix.org"))
        
        let results = await (try? search(query: "@a:matrix.org").get()) ?? []
        
        assertSearchResults(results, toBe: 3)
        let firstUserID = results.first?.userID
        #expect(firstUserID == "@bob:matrix.org")
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func searchResultsShowWhenGetProfileFails() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        
        let results = await (try? search(query: "@a:matrix.org").get()) ?? []
        
        let firstUserID = results.first?.userID
        #expect(firstUserID == "@a:matrix.org")
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    mutating func bareLocalUsernameShowsLocalProfile() async {
        setupJunchatClient()
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForReturnValue = .success(.init(userID: "@hyjktest1:junchat.yyzs120.cn"))
        
        let results = await (try? search(query: "hyjktest1").get()) ?? []
        
        #expect(results.first?.userID == "@hyjktest1:junchat.yyzs120.cn")
        #expect(clientProxy.profileForReceivedUserID == "@hyjktest1:junchat.yyzs120.cn")
    }
    
    @Test
    mutating func atPrefixedLocalUsernameShowsLocalProfile() async {
        setupJunchatClient()
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForReturnValue = .success(.init(userID: "@hyjktest2:junchat.yyzs120.cn"))
        
        let results = await (try? search(query: "@hyjktest2").get()) ?? []
        
        #expect(results.first?.userID == "@hyjktest2:junchat.yyzs120.cn")
        #expect(clientProxy.profileForReceivedUserID == "@hyjktest2:junchat.yyzs120.cn")
    }
    
    @Test
    mutating func mixedCaseBareLocalUsernameShowsLowercasedLocalProfile() async {
        setupJunchatClient()
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForReturnValue = .success(.init(userID: "@hyjktest2:junchat.yyzs120.cn"))
        
        let results = await (try? search(query: "Hyjktest2").get()) ?? []
        
        #expect(results.first?.userID == "@hyjktest2:junchat.yyzs120.cn")
        #expect(clientProxy.profileForReceivedUserID == "@hyjktest2:junchat.yyzs120.cn")
    }
    
    @Test
    mutating func localUsernameWithDomainButNoSigilShowsLocalProfile() async {
        setupJunchatClient()
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForReturnValue = .success(.init(userID: "@hyjktest1:junchat.yyzs120.cn"))
        
        let results = await (try? search(query: "hyjktest1:junchat.yyzs120.cn").get()) ?? []
        
        #expect(results.first?.userID == "@hyjktest1:junchat.yyzs120.cn")
        #expect(clientProxy.profileForReceivedUserID == "@hyjktest1:junchat.yyzs120.cn")
    }
    
    @Test
    mutating func remoteMatrixIdentifierIsNotProfileQueried() async {
        setupJunchatClient()
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [
            .init(userID: "@local:junchat.yyzs120.cn"),
            .init(userID: "@remote:matrix.org")
        ], limited: false))
        clientProxy.profileForReturnValue = .success(.init(userID: "@remote:matrix.org"))
        
        let results = await (try? search(query: "@remote:matrix.org").get()) ?? []
        
        #expect(results.map(\.userID) == ["@local:junchat.yyzs120.cn"])
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    mutating func searchResultsAreLimitedToLocalHomeserver() async {
        setupJunchatClient()
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [
            .init(userID: "@alice:junchat.yyzs120.cn"),
            .init(userID: "@alice:matrix.org")
        ], limited: false))
        clientProxy.profileForReturnValue = .success(.init(userID: "@alice:junchat.yyzs120.cn"))
        
        let results = await (try? search(query: "alice").get()) ?? []
        
        #expect(results.map(\.userID) == ["@alice:junchat.yyzs120.cn"])
    }
    
    // MARK: - Private
    
    private func assertSearchResults(_ results: [UserProfileProxy], toBe count: Int) {
        #expect(count >= 0)
        #expect(results.count == count)
        #expect(results.isEmpty == (count == 0))
    }
    
    private func search(query: String) async -> Result<[UserProfileProxy], UserDiscoveryErrorType> {
        await service.searchProfiles(with: query)
    }
    
    private mutating func setupJunchatClient() {
        clientProxy = .init(.init(userID: "@foo:junchat.yyzs120.cn"))
        service = UserDiscoveryService(clientProxy: clientProxy)
    }
}
