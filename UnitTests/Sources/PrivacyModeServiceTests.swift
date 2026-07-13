//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@Suite(.serialized)
struct PrivacyModeHTTPTransportTests {
    @Test
    func resolvesPathPrefixedHomeserverAndEncodesIdentifiers() async throws {
        let session = makeURLSession()
        let transport = PrivacyModeHTTPTransport(sessionProvider: {
                                                     makeSession(accessToken: "secret-token",
                                                                 userID: "@alice/ops:example.org",
                                                                 homeserverURL: "https://matrix.example.org/prefix/")
                                                 },
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
    func readsAFreshClientSessionSnapshotForEachRequest() async throws {
        var configuration = ClientSDKMock.Configuration()
        configuration.session = makeSession(accessToken: "first-token",
                                            userID: "@alice:old.example.org",
                                            homeserverURL: "https://old.example.org/prefix")
        let client = ClientSDKMock(configuration: configuration)
        let transport = PrivacyModeHTTPTransport(client: client, urlSession: makeURLSession())
        PrivacyModeURLProtocol.response = (200, Data(#"{"enabled":true}"#.utf8))

        _ = await transport.load(roomID: "!room:example.org")
        client.sessionReturnValue = makeSession(accessToken: "refreshed-token",
                                                userID: "@alice:new.example.org",
                                                homeserverURL: "https://new.example.org/base")
        _ = await transport.load(roomID: "!room:example.org")

        #expect(PrivacyModeURLProtocol.requests.count == 2)
        let firstRequest = try #require(PrivacyModeURLProtocol.requests.first)
        let secondRequest = try #require(PrivacyModeURLProtocol.requests.last)
        #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
        #expect(firstRequest.url?.host == "old.example.org")
        #expect(secondRequest.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-token")
        #expect(secondRequest.url?.absoluteString.contains("/user/%40alice%3Anew.example.org/") == true)
        #expect(secondRequest.url?.host == "new.example.org")
    }

    @Test
    func cancellingAnInFlightGetDoesNotRetry() async throws {
        let transport = makeTransport()
        PrivacyModeURLProtocol.results = [.pending]

        let task = Task { await transport.load(roomID: "!room:example.org") }
        try await waitForRequestCount(1)
        task.cancel()

        guard case .failure(.cancelled) = await task.value else {
            Issue.record("Expected the cancelled GET to return cancellation.")
            return
        }
        #expect(PrivacyModeURLProtocol.requestCount == 1)
    }

    @Test
    func cancellingAnInFlightPutDoesNotRetry() async throws {
        let transport = makeTransport()
        PrivacyModeURLProtocol.results = [.pending]

        let task = Task { await transport.setEnabled(true, roomID: "!room:example.org") }
        try await waitForRequestCount(1)
        task.cancel()

        guard case .failure(.cancelled) = await task.value else {
            Issue.record("Expected the cancelled PUT to return cancellation.")
            return
        }
        #expect(PrivacyModeURLProtocol.requestCount == 1)
    }

    @Test
    func restoredUserSessionConstructionUsesTheCurrentSDKClient() async throws {
        let urlSession = makeURLSession()
        let currentSession = makeSession(accessToken: "current-token",
                                         userID: "@current:example.org",
                                         homeserverURL: "https://current.example.org/prefix")
        var configuration = ClientSDKMock.Configuration()
        configuration.session = currentSession
        let client = ClientSDKMock(configuration: configuration)
        let store = UserSessionStore(keychainController: KeychainControllerMock(),
                                     appSettings: AppSettings(),
                                     analyticsService: ServiceLocator.shared.analytics,
                                     appHooks: AppHooks(),
                                     networkMonitor: NetworkMonitorMock.default,
                                     privacyModeURLSession: urlSession)
        let userSession = await store.buildUserSessionWithClient(ClientProxyMock(.init(userID: "@persisted:old.example.org")),
                                                                 client: client)
        PrivacyModeURLProtocol.response = (200, Data(#"{"enabled":false}"#.utf8))

        #expect(await userSession.privacyModeService.load(roomID: "!room:example.org") == .success(false))
        let request = try #require(PrivacyModeURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer current-token")
        #expect(request.url?.host == "current.example.org")
        #expect(request.url?.absoluteString.contains("/user/%40current%3Aexample.org/") == true)
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
        PrivacyModeHTTPTransport(sessionProvider: {
                                     makeSession(accessToken: "secret-token",
                                                 userID: "@alice:example.org",
                                                 homeserverURL: "https://matrix.example.org")
                                 },
                                 urlSession: makeURLSession(),
                                 maximumResponseSize: maximumResponseSize)
    }

    private func makeURLSession() -> URLSession {
        PrivacyModeURLProtocol.lastRequest = nil
        PrivacyModeURLProtocol.requestCount = 0
        PrivacyModeURLProtocol.requests = []
        PrivacyModeURLProtocol.results = []
        PrivacyModeURLProtocol.responseHeaders = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyModeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSession(accessToken: String, userID: String, homeserverURL: String) -> Session {
        Session(accessToken: accessToken,
                refreshToken: nil,
                userId: userID,
                deviceId: "DEVICE",
                homeserverUrl: homeserverURL,
                oauthData: nil,
                slidingSyncVersion: .native)
    }

    private func waitForRequestCount(_ expectedCount: Int) async throws {
        for _ in 0..<100 where PrivacyModeURLProtocol.requestCount < expectedCount {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(PrivacyModeURLProtocol.requestCount == expectedCount)
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
    func absentMigrationPutCompletesBeforeLoadReturns() async throws {
        let transport = PendingMigrationPutTransport()
        let service = await PrivacyModeService(userID: "@alice:example.org",
                                               transport: transport,
                                               migrationStore: PrivacyModeMigrationStoreMock(legacyRoomIDs: [roomID]))
        let completion = PrivacyModeLoadCompletionProbe()
        let loadTask = Task {
            let result = await service.load(roomID: roomID)
            await completion.record(result)
            return result
        }

        try await transport.waitUntilSetStarts()
        #expect(await completion.result == nil)

        await transport.completeSet()
        #expect(await loadTask.value == .success(true))
        #expect(await completion.result == .success(true))
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

    @Test
    func twoServicesForTheSameAccountMigrateAnAbsentRoomOnlyOnce() async {
        let migrationStore = PrivacyModeMigrationStoreMock(legacyRoomIDs: [roomID])
        let remoteState = PrivacyModeRemoteStateStore()
        let coordinator = PrivacyModeOperationCoordinator()
        let firstTransport = PrivacyModeRemoteStateTransport(remoteState: remoteState, loadDelay: .milliseconds(50))
        let secondTransport = PrivacyModeRemoteStateTransport(remoteState: remoteState, loadDelay: .milliseconds(50))
        let firstService = await PrivacyModeService(userID: "@alice:example.org",
                                                    transport: firstTransport,
                                                    migrationStore: migrationStore,
                                                    operationCoordinator: coordinator)
        let secondService = await PrivacyModeService(userID: "@alice:example.org",
                                                     transport: secondTransport,
                                                     migrationStore: migrationStore,
                                                     operationCoordinator: coordinator)

        async let firstResult = firstService.load(roomID: roomID)
        async let secondResult = secondService.load(roomID: roomID)
        #expect(await [firstResult, secondResult] == [.success(true), .success(true)])
        #expect(await remoteState.setInvocations == [true])
    }

    @Test
    func migrationAndToggleAcrossServicesFinishDisabled() async throws {
        let migrationStore = PrivacyModeMigrationStoreMock(legacyRoomIDs: [roomID])
        let remoteState = PrivacyModeRemoteStateStore()
        let coordinator = PrivacyModeOperationCoordinator()
        let migrationTransport = PrivacyModeRemoteStateTransport(remoteState: remoteState,
                                                                 forcedLoadState: .absent,
                                                                 loadDelay: .milliseconds(50))
        let toggleTransport = PrivacyModeRemoteStateTransport(remoteState: remoteState,
                                                              forcedLoadState: .present(enabled: true))
        let migrationService = await PrivacyModeService(userID: "@alice:example.org",
                                                        transport: migrationTransport,
                                                        migrationStore: migrationStore,
                                                        operationCoordinator: coordinator)
        let toggleService = await PrivacyModeService(userID: "@alice:example.org",
                                                     transport: toggleTransport,
                                                     migrationStore: migrationStore,
                                                     operationCoordinator: coordinator)

        let migrationTask = Task { await migrationService.load(roomID: roomID) }
        try await Task.sleep(for: .milliseconds(10))
        let toggleResult = await toggleService.toggle(roomID: roomID)

        #expect(await migrationTask.value == .success(true))
        #expect(toggleResult == .success(false))
        #expect(await remoteState.enabled == false)
        #expect(await remoteState.setInvocations == [true, false])
    }

    @Test
    func transportCancellationMapsToServiceCancellation() async {
        let loadTransport = PrivacyModeTransportMock(loadResults: [.failure(.cancelled)])
        let loadService = await PrivacyModeService(userID: "@alice:example.org",
                                                   transport: loadTransport,
                                                   migrationStore: PrivacyModeMigrationStoreMock())
        #expect(await loadService.load(roomID: roomID) == .failure(.cancelled))

        let toggleTransport = PrivacyModeTransportMock(loadResults: [.success(.present(enabled: false))],
                                                       setResults: [.failure(.cancelled)])
        let toggleService = await PrivacyModeService(userID: "@alice:example.org",
                                                     transport: toggleTransport,
                                                     migrationStore: PrivacyModeMigrationStoreMock())
        #expect(await toggleService.toggle(roomID: roomID) == .failure(.cancelled))
    }

    @Test
    func coordinatorDoesNotSerializeDifferentAccountsOrRooms() async {
        let coordinator = PrivacyModeOperationCoordinator()
        let concurrencyProbe = PrivacyModeConcurrencyProbe()
        let transport = ProbedPrivacyModeTransport(concurrencyProbe: concurrencyProbe)
        let migrationStore = PrivacyModeMigrationStoreMock()
        let accountAService = await PrivacyModeService(userID: "@alice:example.org",
                                                       transport: transport,
                                                       migrationStore: migrationStore,
                                                       operationCoordinator: coordinator)
        let accountBService = await PrivacyModeService(userID: "@bob:example.org",
                                                       transport: transport,
                                                       migrationStore: migrationStore,
                                                       operationCoordinator: coordinator)

        async let accountARoomOne = accountAService.load(roomID: "!one:example.org")
        async let accountARoomTwo = accountAService.load(roomID: "!two:example.org")
        async let accountBRoomOne = accountBService.load(roomID: "!one:example.org")

        #expect(await [accountARoomOne, accountARoomTwo, accountBRoomOne] == [.success(false), .success(false), .success(false)])
        #expect(await concurrencyProbe.maximumConcurrentCount == 3)
    }

    private func makeMigrationStore(legacyRoomIDs: Set<String>) throws -> PrivacyModeMigrationStore {
        let suiteName = "PrivacyModeServiceTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        try userDefaults.set(JSONEncoder().encode(legacyRoomIDs), forKey: "junchatPrivacyModeRoomIDs")
        return PrivacyModeMigrationStore(userDefaults: userDefaults)
    }
}

private actor PrivacyModeConcurrencyProbe {
    private var concurrentCount = 0
    private(set) var maximumConcurrentCount = 0

    func begin() {
        concurrentCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, concurrentCount)
    }

    func end() {
        concurrentCount -= 1
    }
}

private actor ProbedPrivacyModeTransport: PrivacyModeTransportProtocol {
    private let concurrencyProbe: PrivacyModeConcurrencyProbe

    init(concurrencyProbe: PrivacyModeConcurrencyProbe) {
        self.concurrencyProbe = concurrencyProbe
    }

    func load(roomID: String) async -> Result<PrivacyModeRemoteState, PrivacyModeTransportError> {
        await concurrencyProbe.begin()
        try? await Task.sleep(for: .milliseconds(50))
        await concurrencyProbe.end()
        return .success(.present(enabled: false))
    }

    func setEnabled(_ enabled: Bool, roomID: String) -> Result<Void, PrivacyModeTransportError> {
        .success(())
    }
}

private actor PrivacyModeLoadCompletionProbe {
    private(set) var result: Result<Bool, PrivacyModeServiceError>?

    func record(_ result: Result<Bool, PrivacyModeServiceError>) {
        self.result = result
    }
}

private actor PendingMigrationPutTransport: PrivacyModeTransportProtocol {
    private var setContinuation: CheckedContinuation<Void, Never>?
    private var setStarted = false

    func load(roomID: String) -> Result<PrivacyModeRemoteState, PrivacyModeTransportError> {
        .success(.absent)
    }

    func setEnabled(_ enabled: Bool, roomID: String) async -> Result<Void, PrivacyModeTransportError> {
        setStarted = true
        await withCheckedContinuation { continuation in
            setContinuation = continuation
        }
        return .success(())
    }

    func waitUntilSetStarts() async throws {
        for _ in 0..<100 where !setStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(setStarted)
    }

    func completeSet() {
        setContinuation?.resume()
        setContinuation = nil
    }
}

private actor PrivacyModeRemoteStateStore {
    private(set) var enabled: Bool?
    private(set) var setInvocations = [Bool]()

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        setInvocations.append(enabled)
    }
}

private actor PrivacyModeRemoteStateTransport: PrivacyModeTransportProtocol {
    private let remoteState: PrivacyModeRemoteStateStore
    private let forcedLoadState: PrivacyModeRemoteState?
    private let loadDelay: Duration

    init(remoteState: PrivacyModeRemoteStateStore,
         forcedLoadState: PrivacyModeRemoteState? = nil,
         loadDelay: Duration = .zero) {
        self.remoteState = remoteState
        self.forcedLoadState = forcedLoadState
        self.loadDelay = loadDelay
    }

    func load(roomID: String) async -> Result<PrivacyModeRemoteState, PrivacyModeTransportError> {
        let state = if let forcedLoadState {
            forcedLoadState
        } else if let enabled = await remoteState.enabled {
            PrivacyModeRemoteState.present(enabled: enabled)
        } else {
            PrivacyModeRemoteState.absent
        }
        try? await Task.sleep(for: loadDelay)
        return .success(state)
    }

    func setEnabled(_ enabled: Bool, roomID: String) async -> Result<Void, PrivacyModeTransportError> {
        await remoteState.setEnabled(enabled)
        return .success(())
    }
}

private final class PrivacyModeURLProtocol: URLProtocol {
    enum Result {
        case failure(Error)
        case pending
        case response(statusCode: Int, data: Data)
    }

    static var response = (statusCode: 200, data: Data())
    static var results = [Result]()
    static var lastRequest: URLRequest?
    static var requestCount = 0
    static var requests = [URLRequest]()
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
        Self.requests.append(request)
        if !Self.results.isEmpty {
            switch Self.results.removeFirst() {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
                return
            case .pending:
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
