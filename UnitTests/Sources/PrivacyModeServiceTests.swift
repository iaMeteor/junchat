//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@Suite(.serialized)
struct PrivacyModeHTTPTransportTests {
    @Test
    func resolvesPathPrefixedHomeserverAndEncodesIdentifiers() async throws {
        let session = makeURLSession()
        let transport = PrivacyModeHTTPTransport(homeserverURL: "https://matrix.example.org/prefix/",
                                                 userID: "@alice/ops:example.org",
                                                 accessToken: "secret-token",
                                                 urlSession: session)
        PrivacyModeURLProtocol.response = (200, Data(#"{"enabled":true}"#.utf8))

        let result = await transport.load(roomID: "!room/part:example.org")

        #expect(result == .success(.present(enabled: true)))
        let request = try #require(PrivacyModeURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://matrix.example.org/prefix/_matrix/client/v3/user/%40alice%2Fops%3Aexample.org/rooms/%21room%2Fpart%3Aexample.org/account_data/com.heyujk.junchat.privacy_mode")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test
    func distinguishesAbsentFromExplicitFalse() async {
        let transport = makeTransport()
        PrivacyModeURLProtocol.response = (404, Data())
        #expect(await transport.load(roomID: "!room:example.org") == .success(.absent))

        PrivacyModeURLProtocol.response = (200, Data(#"{"enabled":false}"#.utf8))
        #expect(await transport.load(roomID: "!room:example.org") == .success(.present(enabled: false)))
    }

    @Test
    func retriesOnceAfterImmediateNetworkFailure() async {
        let transport = makeTransport()
        PrivacyModeURLProtocol.results = [
            .failure(URLError(.timedOut)),
            .response(statusCode: 200, data: Data(#"{"enabled":true}"#.utf8))
        ]

        #expect(await transport.load(roomID: "!room:example.org") == .success(.present(enabled: true)))
        #expect(PrivacyModeURLProtocol.requestCount == 2)
    }

    @Test
    func rejectsMalformedAndOversizedResponses() async {
        let transport = makeTransport(maximumResponseSize: 32)
        PrivacyModeURLProtocol.response = (200, Data(#"{"enabled":"yes"}"#.utf8))
        #expect(await transport.load(roomID: "!room:example.org") == .failure(.malformedResponse))

        PrivacyModeURLProtocol.response = (200, Data(repeating: 0x20, count: 33))
        #expect(await transport.load(roomID: "!room:example.org") == .failure(.responseTooLarge))
    }

    @Test
    func rejectsOversizedPutResponse() async {
        let transport = makeTransport(maximumResponseSize: 32)
        PrivacyModeURLProtocol.response = (200, Data(repeating: 0x20, count: 33))

        let result = await transport.setEnabled(true, roomID: "!room:example.org")
        guard case .failure(.responseTooLarge) = result else {
            Issue.record("Expected an oversized PUT response failure, got \(result).")
            return
        }
    }

    @Test
    func rejectsPutResponseWithOversizedContentLength() async {
        let transport = makeTransport(maximumResponseSize: 32)
        PrivacyModeURLProtocol.response = (200, Data())
        PrivacyModeURLProtocol.responseHeaders = ["Content-Length": "33"]

        let result = await transport.setEnabled(true, roomID: "!room:example.org")
        guard case .failure(.responseTooLarge) = result else {
            Issue.record("Expected an oversized PUT content length failure, got \(result).")
            return
        }
    }

    private func makeTransport(maximumResponseSize: Int = 4096) -> PrivacyModeHTTPTransport {
        PrivacyModeHTTPTransport(homeserverURL: "https://matrix.example.org",
                                 userID: "@alice:example.org",
                                 accessToken: "secret-token",
                                 urlSession: makeURLSession(),
                                 maximumResponseSize: maximumResponseSize)
    }

    private func makeURLSession() -> URLSession {
        PrivacyModeURLProtocol.lastRequest = nil
        PrivacyModeURLProtocol.requestCount = 0
        PrivacyModeURLProtocol.results = []
        PrivacyModeURLProtocol.responseHeaders = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyModeURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized)
struct PrivacyModeServiceTests {
    private let roomID = "!private:example.org"

    @Test
    func explicitFalseWinsOverClaimedLegacyTrue() async {
        let migrationStore = PrivacyModeMigrationStoreMock(legacyRoomIDs: [roomID])
        let transport = PrivacyModeTransportMock(loadResults: [.success(.present(enabled: false))])
        let service = await PrivacyModeService(userID: "@alice:example.org", transport: transport, migrationStore: migrationStore)

        #expect(await service.load(roomID: roomID) == .success(false))
        #expect(await transport.setInvocations.isEmpty)
        #expect(await migrationStore.pendingRoomIDs(for: "@alice:example.org").isEmpty)
    }

    @Test
    func absentStateMigratesOnlyOnce() async {
        let migrationStore = PrivacyModeMigrationStoreMock(legacyRoomIDs: [roomID])
        let transport = PrivacyModeTransportMock(loadResults: [.success(.absent), .success(.present(enabled: true))],
                                                 setResults: [.success(())])
        let service = await PrivacyModeService(userID: "@alice:example.org", transport: transport, migrationStore: migrationStore)

        #expect(await service.load(roomID: roomID) == .success(true))
        #expect(await service.load(roomID: roomID) == .success(true))
        #expect(await transport.setInvocations == [.init(enabled: true, roomID: roomID)])
    }

    @Test
    func failedMigrationPutRemainsRetryable() async {
        let migrationStore = PrivacyModeMigrationStoreMock(legacyRoomIDs: [roomID])
        let transport = PrivacyModeTransportMock(loadResults: [.success(.absent), .success(.absent)],
                                                 setResults: [.failure(.network), .success(())])
        let service = await PrivacyModeService(userID: "@alice:example.org", transport: transport, migrationStore: migrationStore)

        #expect(await service.load(roomID: roomID) == .failure(.transport(.network)))
        #expect(await migrationStore.pendingRoomIDs(for: "@alice:example.org") == [roomID])
        #expect(await service.load(roomID: roomID) == .success(true))
        #expect(await migrationStore.pendingRoomIDs(for: "@alice:example.org").isEmpty)
    }

    @Test
    func secondAccountNeverInheritsClaimedLegacyRooms() async throws {
        let migrationStore = try makeMigrationStore(legacyRoomIDs: [roomID])
        let accountATransport = PrivacyModeTransportMock(loadResults: [.success(.absent)], setResults: [.failure(.network)])
        let accountAService = await PrivacyModeService(userID: "@alice:example.org", transport: accountATransport, migrationStore: migrationStore)
        _ = await accountAService.load(roomID: roomID)

        let accountBTransport = PrivacyModeTransportMock(loadResults: [.success(.absent)])
        let accountBService = await PrivacyModeService(userID: "@bob:example.org", transport: accountBTransport, migrationStore: migrationStore)

        #expect(await accountBService.load(roomID: roomID) == .success(false))
        #expect(await accountBTransport.setInvocations.isEmpty)
    }

    @Test
    func firstAccountClaimsLegacyRoomsBeforeAnyRoomLoad() async throws {
        let migrationStore = try makeMigrationStore(legacyRoomIDs: [roomID])
        let accountAService = await PrivacyModeService(userID: "@alice:example.org",
                                                       transport: PrivacyModeTransportMock(),
                                                       migrationStore: migrationStore)
        _ = accountAService

        let accountBTransport = PrivacyModeTransportMock(loadResults: [.success(.absent)], setResults: [.success(())])
        let accountBService = await PrivacyModeService(userID: "@bob:example.org", transport: accountBTransport, migrationStore: migrationStore)

        #expect(await accountBService.load(roomID: roomID) == .success(false))
        #expect(await accountBTransport.setInvocations.isEmpty)
    }

    @Test
    func reloggedOwnerContinuesFailedMigration() async throws {
        let migrationStore = try makeMigrationStore(legacyRoomIDs: [roomID])
        let firstTransport = PrivacyModeTransportMock(loadResults: [.success(.absent)], setResults: [.failure(.network)])
        let firstService = await PrivacyModeService(userID: "@alice:example.org", transport: firstTransport, migrationStore: migrationStore)
        _ = await firstService.load(roomID: roomID)

        let reloginTransport = PrivacyModeTransportMock(loadResults: [.success(.absent)], setResults: [.success(())])
        let reloginService = await PrivacyModeService(userID: "@alice:example.org", transport: reloginTransport, migrationStore: migrationStore)

        #expect(await reloginService.load(roomID: roomID) == .success(true))
        #expect(await reloginTransport.setInvocations == [.init(enabled: true, roomID: roomID)])
    }

    @Test
    func fetchAndToggleAreSerializedWithoutStaleOverwrite() async throws {
        let migrationStore = PrivacyModeMigrationStoreMock()
        let transport = PrivacyModeTransportMock(loadResults: [.success(.present(enabled: false))],
                                                 setResults: [.success(())],
                                                 operationDelay: .milliseconds(50))
        let service = await PrivacyModeService(userID: "@alice:example.org", transport: transport, migrationStore: migrationStore)

        let fetchTask = Task { await service.load(roomID: roomID) }
        try await Task.sleep(for: .milliseconds(10))
        let toggleTask = Task { await service.toggle(roomID: roomID) }

        #expect(await fetchTask.value == .success(false))
        #expect(await toggleTask.value == .success(true))
        #expect(await service.cachedValue(roomID: roomID) == true)
        #expect(await transport.maximumConcurrentOperationCount == 1)
    }

    @Test
    func cancelledWaiterDoesNotExecuteADeferredNetworkOperation() async throws {
        let migrationStore = PrivacyModeMigrationStoreMock()
        let transport = PrivacyModeTransportMock(loadResults: [.success(.present(enabled: false)), .success(.present(enabled: true))],
                                                 operationDelay: .milliseconds(50))
        let service = await PrivacyModeService(userID: "@alice:example.org", transport: transport, migrationStore: migrationStore)

        let firstLoad = Task { await service.load(roomID: roomID) }
        try await Task.sleep(for: .milliseconds(10))
        let cancelledLoad = Task { await service.load(roomID: roomID) }
        try await Task.sleep(for: .milliseconds(10))
        cancelledLoad.cancel()

        #expect(await firstLoad.value == .success(false))
        #expect(await cancelledLoad.value == .failure(.cancelled))
        try await Task.sleep(for: .milliseconds(75))
        #expect(await transport.loadRoomIDReceivedInvocations == [roomID])
    }

    private func makeMigrationStore(legacyRoomIDs: Set<String>) throws -> PrivacyModeMigrationStore {
        let suiteName = "PrivacyModeServiceTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        try userDefaults.set(JSONEncoder().encode(legacyRoomIDs), forKey: "junchatPrivacyModeRoomIDs")
        return PrivacyModeMigrationStore(userDefaults: userDefaults)
    }
}

private final class PrivacyModeURLProtocol: URLProtocol {
    enum Result {
        case failure(Error)
        case response(statusCode: Int, data: Data)
    }

    static var response = (statusCode: 200, data: Data())
    static var results = [Result]()
    static var lastRequest: URLRequest?
    static var requestCount = 0
    static var responseHeaders: [String: String]?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        Self.requestCount += 1
        if !Self.results.isEmpty {
            switch Self.results.removeFirst() {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
                return
            case .response(let statusCode, let data):
                Self.response = (statusCode, data)
            }
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.response.statusCode, httpVersion: nil, headerFields: Self.responseHeaders) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private actor PrivacyModeTransportMock: PrivacyModeTransportProtocol {
    struct SetInvocation: Equatable {
        let enabled: Bool
        let roomID: String
    }

    private var loadResults: [Result<PrivacyModeRemoteState, PrivacyModeTransportError>]
    private var setResults: [Result<Void, PrivacyModeTransportError>]
    private let operationDelay: Duration
    private(set) var setInvocations = [SetInvocation]()
    private(set) var loadRoomIDReceivedInvocations = [String]()
    private(set) var maximumConcurrentOperationCount = 0
    private var concurrentOperationCount = 0

    init(loadResults: [Result<PrivacyModeRemoteState, PrivacyModeTransportError>] = [],
         setResults: [Result<Void, PrivacyModeTransportError>] = [],
         operationDelay: Duration = .zero) {
        self.loadResults = loadResults
        self.setResults = setResults
        self.operationDelay = operationDelay
    }

    func load(roomID: String) async -> Result<PrivacyModeRemoteState, PrivacyModeTransportError> {
        await beginOperation()
        defer { endOperation() }
        loadRoomIDReceivedInvocations.append(roomID)
        return loadResults.removeFirst()
    }

    func setEnabled(_ enabled: Bool, roomID: String) async -> Result<Void, PrivacyModeTransportError> {
        await beginOperation()
        defer { endOperation() }
        setInvocations.append(.init(enabled: enabled, roomID: roomID))
        return setResults.removeFirst()
    }

    private func beginOperation() async {
        concurrentOperationCount += 1
        maximumConcurrentOperationCount = max(maximumConcurrentOperationCount, concurrentOperationCount)
        try? await Task.sleep(for: operationDelay)
    }

    private func endOperation() {
        concurrentOperationCount -= 1
    }
}

private actor PrivacyModeMigrationStoreMock: PrivacyModeMigrationStoreProtocol {
    private var legacyRoomIDs: Set<String>
    private var ownerUserID: String?
    private var pendingRoomIDs = Set<String>()

    init(legacyRoomIDs: Set<String> = []) {
        self.legacyRoomIDs = legacyRoomIDs
    }

    func claimLegacyRoomIDs(for userID: String) -> Set<String> {
        if ownerUserID == nil {
            ownerUserID = userID
            pendingRoomIDs = legacyRoomIDs
            legacyRoomIDs.removeAll()
        }
        return ownerUserID == userID ? pendingRoomIDs : []
    }

    func consumeLegacyRoomID(_ roomID: String, for userID: String) {
        guard ownerUserID == userID else { return }
        pendingRoomIDs.remove(roomID)
    }

    func pendingRoomIDs(for userID: String) -> Set<String> {
        ownerUserID == userID ? pendingRoomIDs : []
    }
}
