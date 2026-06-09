//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct ContactsServiceTests {
    private var clientProxy: ClientProxyMock
    private var service: ContactsService
    
    init() {
        clientProxy = .init(.init(userID: "@me:junchat.yyzs120.cn"))
        service = ContactsService(clientProxy: clientProxy)
    }
    
    @Test
    mutating func contactsAreSortedAndExcludeCurrentUser() async throws {
        clientProxy.junchatContactsReturnValue = .success([
            .init(userID: "@zara:junchat.yyzs120.cn", displayName: "Zara"),
            .init(userID: "@me:junchat.yyzs120.cn", displayName: "Me"),
            .init(userID: "@anna:junchat.yyzs120.cn", displayName: "Anna")
        ])
        
        let contacts = try await service.contacts().get()
        
        #expect(contacts.map(\.userID) == [
            "@anna:junchat.yyzs120.cn",
            "@zara:junchat.yyzs120.cn"
        ])
    }
    
    @Test
    mutating func missingDisplayNameSortsByLocalpart() async throws {
        clientProxy.junchatContactsReturnValue = .success([
            .init(userID: "@zhang:junchat.yyzs120.cn", displayName: nil),
            .init(userID: "@alice:junchat.yyzs120.cn", displayName: "Alice")
        ])
        
        let contacts = try await service.contacts().get()
        
        #expect(contacts.map(\.userID) == [
            "@alice:junchat.yyzs120.cn",
            "@zhang:junchat.yyzs120.cn"
        ])
    }
    
    @Test
    mutating func fetchFailureIsForwarded() async {
        clientProxy.junchatContactsReturnValue = .failure(.invalidResponse)
        
        switch await service.contacts() {
        case .success:
            Issue.record("Contacts loading should fail")
        case .failure(let error):
            #expect(error == .failedFetchingContacts)
        }
    }
}
