//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

enum JunchatContactsServiceError: Error, Equatable {
    case cancelled
    case httpStatus(Int)
    case invalidPagination
    case invalidResponse
    case invalidURL
    case malformedResponse
    case network
    case rateLimited
    case responseTooLarge
    case unauthorized
}

struct JunchatContactsServiceLimits {
    let pageSize: Int
    let maximumPageCount: Int
    let maximumPageResponseSize: Int
    let maximumLegacyResponseSize: Int
    let maximumAggregateResponseSize: Int
    let maximumRawContactCount: Int
    let maximumUniqueContactCount: Int
    let maximumCursorSize: Int
    let maximumUserIDSize: Int
    let maximumDisplayNameSize: Int
    let maximumAvatarURLSize: Int

    init(pageSize: Int = 100,
         maximumPageCount: Int = 100,
         maximumPageResponseSize: Int = 1024 * 1024,
         maximumLegacyResponseSize: Int = 8 * 1024 * 1024,
         maximumAggregateResponseSize: Int = 8 * 1024 * 1024,
         maximumRawContactCount: Int = 20000,
         maximumUniqueContactCount: Int = 10000,
         maximumCursorSize: Int = 4 * 1024,
         maximumUserIDSize: Int = 255,
         maximumDisplayNameSize: Int = 1024,
         maximumAvatarURLSize: Int = 2048) {
        self.pageSize = max(1, pageSize)
        self.maximumPageCount = max(1, maximumPageCount)
        self.maximumPageResponseSize = max(1, maximumPageResponseSize)
        self.maximumLegacyResponseSize = max(1, maximumLegacyResponseSize)
        self.maximumAggregateResponseSize = max(1, maximumAggregateResponseSize)
        self.maximumRawContactCount = max(1, maximumRawContactCount)
        self.maximumUniqueContactCount = max(1, maximumUniqueContactCount)
        self.maximumCursorSize = max(1, maximumCursorSize)
        self.maximumUserIDSize = max(1, maximumUserIDSize)
        self.maximumDisplayNameSize = max(0, maximumDisplayNameSize)
        self.maximumAvatarURLSize = max(0, maximumAvatarURLSize)
    }
}

struct JunchatContactsService {
    private struct ContactsPage: Decodable {
        let contacts: [RemoteContact]
        let nextBatch: String?

        enum CodingKeys: String, CodingKey {
            case contacts
            case nextBatch = "next_batch"
        }
    }

    private struct RemoteContact: Decodable {
        let userID: String
        let displayName: String?
        let avatarURL: String?

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case displayName = "display_name"
            case avatarURL = "avatar_url"
        }
    }

    private struct VisibilityPayload: Codable {
        let hidden: Bool
    }

    private struct ResponseData {
        let data: Data
        let response: HTTPURLResponse
        let session: Session
    }

    private struct AccountIdentity: Equatable {
        let userID: String
        let homeserverURL: String
    }

    private struct LoadedContactsPage {
        let page: ContactsPage
        let accountIdentity: AccountIdentity
        let aggregateResponseSize: Int
    }

    private static let contactsVisibilityAccountDataType = "com.heyujk.junchat.contacts_visibility"
    private static let unreservedPathCharacters = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))

    private let sessionProvider: @Sendable () throws -> Session
    private let urlSession: URLSession
    private let limits: JunchatContactsServiceLimits

    init(client: ClientProtocol,
         urlSession: URLSession = .shared,
         limits: JunchatContactsServiceLimits = .init()) {
        self.init(sessionProvider: { try client.session() },
                  urlSession: urlSession,
                  limits: limits)
    }

    init(sessionProvider: @escaping @Sendable () throws -> Session,
         urlSession: URLSession = .shared,
         limits: JunchatContactsServiceLimits = .init()) {
        self.sessionProvider = sessionProvider
        self.urlSession = urlSession
        self.limits = limits
    }

    func contacts() async -> Result<[JunchatContact], JunchatContactsServiceError> {
        var contacts = [JunchatContact]()
        var seenUserIDs = Set<String>()
        var seenCursors = Set<String>()
        var cursor: String?
        var pageCount = 0
        var aggregateResponseSize = 0
        var rawContactCount = 0
        var expectedAccountIdentity: AccountIdentity?

        while pageCount < limits.maximumPageCount {
            guard !Task.isCancelled else {
                return .failure(.cancelled)
            }

            let isFirstPage = pageCount == 0
            let loadedPageResult = await loadContactsPage(cursor: cursor,
                                                          isFirstPage: isFirstPage,
                                                          expectedAccountIdentity: expectedAccountIdentity,
                                                          aggregateResponseSize: aggregateResponseSize)
            guard case .success(let loadedPage) = loadedPageResult else {
                return loadedPageResult.map { _ in [] }
            }
            let page = loadedPage.page
            expectedAccountIdentity = loadedPage.accountIdentity
            aggregateResponseSize = loadedPage.aggregateResponseSize
            pageCount += 1

            if let error = append(page.contacts,
                                  contacts: &contacts,
                                  seenUserIDs: &seenUserIDs,
                                  rawContactCount: &rawContactCount) {
                return .failure(error)
            }

            guard let nextBatch = page.nextBatch else {
                return .success(contacts)
            }
            guard !nextBatch.isEmpty,
                  nextBatch.utf8.count <= limits.maximumCursorSize,
                  seenCursors.insert(nextBatch).inserted else {
                return .failure(.invalidPagination)
            }
            cursor = nextBatch
        }

        return .failure(.invalidPagination)
    }

    func isHiddenFromDirectory() async -> Result<Bool, JunchatContactsServiceError> {
        let responseResult = await authenticatedResponse(maximumBodySize: 4096,
                                                         readSuccessfulBody: true) { session in
            visibilityRequest(session: session)
        }
        guard case .success(let responseData) = responseResult else {
            return responseResult.map { _ in false }
        }
        if responseData.response.statusCode == 404 {
            return .success(false)
        }
        guard 200..<300 ~= responseData.response.statusCode else {
            return .failure(error(for: responseData.response.statusCode))
        }
        guard let payload = try? JSONDecoder().decode(VisibilityPayload.self, from: responseData.data) else {
            return .failure(.malformedResponse)
        }
        return .success(payload.hidden)
    }

    func setHiddenFromDirectory(_ hidden: Bool) async -> Result<Void, JunchatContactsServiceError> {
        let responseResult = await authenticatedResponse(maximumBodySize: 0,
                                                         readSuccessfulBody: false) { session in
            guard var request = visibilityRequest(session: session) else {
                return nil
            }
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(VisibilityPayload(hidden: hidden))
            return request
        }
        guard case .success(let responseData) = responseResult else {
            return responseResult.map { _ in () }
        }
        guard 200..<300 ~= responseData.response.statusCode else {
            return .failure(error(for: responseData.response.statusCode))
        }
        return .success(())
    }

    private func fieldsAreWithinLimits(_ contact: RemoteContact) -> Bool {
        contact.userID.utf8.count <= limits.maximumUserIDSize &&
            (contact.displayName?.utf8.count ?? 0) <= limits.maximumDisplayNameSize &&
            (contact.avatarURL?.utf8.count ?? 0) <= limits.maximumAvatarURLSize
    }

    private func loadContactsPage(cursor: String?,
                                  isFirstPage: Bool,
                                  expectedAccountIdentity: AccountIdentity?,
                                  aggregateResponseSize: Int) async -> Result<LoadedContactsPage, JunchatContactsServiceError> {
        let maximumResponseSize = isFirstPage ? limits.maximumLegacyResponseSize : limits.maximumPageResponseSize
        let responseResult = await authenticatedResponse(maximumBodySize: maximumResponseSize,
                                                         readSuccessfulBody: true,
                                                         requiredAccountIdentity: expectedAccountIdentity) { session in
            contactsRequest(session: session, cursor: cursor)
        }
        let responseData: ResponseData
        switch responseResult {
        case .success(let value):
            responseData = value
        case .failure(let error):
            return .failure(error)
        }
        guard 200..<300 ~= responseData.response.statusCode else {
            return .failure(error(for: responseData.response.statusCode))
        }

        let accountIdentity = accountIdentity(for: responseData.session)

        let newAggregateResponseSize = aggregateResponseSize + responseData.data.count
        guard newAggregateResponseSize <= limits.maximumAggregateResponseSize else {
            return .failure(.responseTooLarge)
        }
        switch decodePage(from: responseData.data, isFirstPage: isFirstPage) {
        case .success(let page):
            return .success(.init(page: page,
                                  accountIdentity: accountIdentity,
                                  aggregateResponseSize: newAggregateResponseSize))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func decodePage(from data: Data, isFirstPage: Bool) -> Result<ContactsPage, JunchatContactsServiceError> {
        let page: ContactsPage
        do {
            page = try JSONDecoder().decode(ContactsPage.self, from: data)
        } catch {
            return .failure(.malformedResponse)
        }

        let isLegacyCompleteList = isFirstPage && page.nextBatch == nil
        guard isLegacyCompleteList || (page.contacts.count <= limits.pageSize && data.count <= limits.maximumPageResponseSize) else {
            return .failure(data.count > limits.maximumPageResponseSize ? .responseTooLarge : .malformedResponse)
        }
        return .success(page)
    }

    private func append(_ remoteContacts: [RemoteContact],
                        contacts: inout [JunchatContact],
                        seenUserIDs: inout Set<String>,
                        rawContactCount: inout Int) -> JunchatContactsServiceError? {
        rawContactCount += remoteContacts.count
        guard rawContactCount <= limits.maximumRawContactCount else {
            return .responseTooLarge
        }

        for remoteContact in remoteContacts {
            guard fieldsAreWithinLimits(remoteContact) else {
                return .malformedResponse
            }
            guard MatrixEntityRegex.isMatrixUserIdentifier(remoteContact.userID),
                  seenUserIDs.insert(remoteContact.userID).inserted else {
                continue
            }
            guard contacts.count < limits.maximumUniqueContactCount else {
                return .responseTooLarge
            }

            let avatarURL = remoteContact.avatarURL
                .flatMap(URL.init(string:))
                .flatMap { $0.scheme == nil ? nil : $0 }
            contacts.append(.init(userID: remoteContact.userID,
                                  displayName: remoteContact.displayName,
                                  avatarURL: avatarURL))
        }
        return nil
    }

    private func contactsRequest(session: Session, cursor: String?) -> URLRequest? {
        guard var components = baseURLComponents(session: session) else {
            return nil
        }
        components.percentEncodedPath = joinedPath(basePath: components.percentEncodedPath,
                                                   components: ["_matrix", "client", "v3", "junchat", "contacts"])
        components.queryItems = [URLQueryItem(name: "limit", value: String(limits.pageSize))]
        if let cursor {
            components.queryItems?.append(.init(name: "from", value: cursor))
        }
        guard let url = components.url else {
            return nil
        }
        return authenticatedRequest(url: url, session: session)
    }

    private func visibilityRequest(session: Session) -> URLRequest? {
        guard var components = baseURLComponents(session: session) else {
            return nil
        }
        components.percentEncodedPath = joinedPath(basePath: components.percentEncodedPath,
                                                   components: ["_matrix", "client", "v3", "user", encoded(session.userId), "account_data", encoded(Self.contactsVisibilityAccountDataType)])
        guard let url = components.url else {
            return nil
        }
        return authenticatedRequest(url: url, session: session)
    }

    private func baseURLComponents(session: Session) -> URLComponents? {
        guard let components = URLComponents(string: session.homeserverUrl),
              ["http", "https"].contains(components.scheme?.lowercased()),
              components.host != nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        return components
    }

    private func joinedPath(basePath: String, components: [String]) -> String {
        let trimmedBasePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + ([trimmedBasePath] + components).filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func encoded(_ pathComponent: String) -> String {
        pathComponent.addingPercentEncoding(withAllowedCharacters: Self.unreservedPathCharacters) ?? ""
    }

    private func authenticatedRequest(url: URL, session: Session) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func authenticatedResponse(maximumBodySize: Int,
                                       readSuccessfulBody: Bool,
                                       requiredAccountIdentity: AccountIdentity? = nil,
                                       request: (Session) -> URLRequest?) async -> Result<ResponseData, JunchatContactsServiceError> {
        let initialSession: Session
        do {
            initialSession = try sessionProvider()
        } catch {
            return .failure(.network)
        }
        guard requiredAccountIdentity == nil || requiredAccountIdentity == accountIdentity(for: initialSession) else {
            return .failure(.invalidResponse)
        }
        guard let initialRequest = request(initialSession) else {
            return .failure(.invalidURL)
        }

        let initialResult = await responseData(for: initialRequest,
                                               session: initialSession,
                                               maximumBodySize: maximumBodySize,
                                               readSuccessfulBody: readSuccessfulBody)
        guard case .success(let initialResponse) = initialResult,
              initialResponse.response.statusCode == 401,
              !Task.isCancelled else {
            return initialResult
        }

        let refreshedSession: Session
        do {
            refreshedSession = try sessionProvider()
        } catch {
            return .failure(.unauthorized)
        }
        guard refreshedSession.userId == initialSession.userId,
              refreshedSession.homeserverUrl == initialSession.homeserverUrl,
              refreshedSession.accessToken != initialSession.accessToken,
              let refreshedRequest = request(refreshedSession) else {
            return .success(initialResponse)
        }
        return await responseData(for: refreshedRequest,
                                  session: refreshedSession,
                                  maximumBodySize: maximumBodySize,
                                  readSuccessfulBody: readSuccessfulBody)
    }

    private func accountIdentity(for session: Session) -> AccountIdentity {
        .init(userID: session.userId, homeserverURL: session.homeserverUrl)
    }

    private func responseData(for request: URLRequest,
                              session: Session,
                              maximumBodySize: Int,
                              readSuccessfulBody: Bool) async -> Result<ResponseData, JunchatContactsServiceError> {
        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard readSuccessfulBody, 200..<300 ~= httpResponse.statusCode else {
                return .success(.init(data: Data(), response: httpResponse, session: session))
            }
            guard httpResponse.expectedContentLength < 0 || httpResponse.expectedContentLength <= Int64(maximumBodySize) else {
                return .failure(.responseTooLarge)
            }

            var data = Data()
            data.reserveCapacity(min(maximumBodySize, max(0, Int(httpResponse.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumBodySize else {
                    return .failure(.responseTooLarge)
                }
                data.append(byte)
            }
            return .success(.init(data: data, response: httpResponse, session: session))
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                return .failure(.cancelled)
            }
            return .failure(.network)
        }
    }

    private func error(for statusCode: Int) -> JunchatContactsServiceError {
        switch statusCode {
        case 401, 403:
            .unauthorized
        case 429:
            .rateLimited
        default:
            .httpStatus(statusCode)
        }
    }
}
