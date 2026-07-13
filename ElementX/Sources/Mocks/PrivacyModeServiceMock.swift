//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

actor PrivacyModeServiceMock: PrivacyModeServiceProtocol {
    private var loadResults: [Result<Bool, PrivacyModeServiceError>]
    private var toggleResults: [Result<Bool, PrivacyModeServiceError>]
    private var cachedValues: [String: Bool]

    private(set) var loadRoomIDReceivedInvocations = [String]()
    private(set) var toggleRoomIDReceivedInvocations = [String]()

    init(loadResults: [Result<Bool, PrivacyModeServiceError>] = [.success(false)],
         toggleResults: [Result<Bool, PrivacyModeServiceError>] = [.success(true)],
         cachedValues: [String: Bool] = [:]) {
        self.loadResults = loadResults
        self.toggleResults = toggleResults
        self.cachedValues = cachedValues
    }

    func load(roomID: String) -> Result<Bool, PrivacyModeServiceError> {
        loadRoomIDReceivedInvocations.append(roomID)
        let result = loadResults.count == 1 ? loadResults[0] : loadResults.removeFirst()
        if case .success(let enabled) = result {
            cachedValues[roomID] = enabled
        }
        return result
    }

    func toggle(roomID: String) -> Result<Bool, PrivacyModeServiceError> {
        toggleRoomIDReceivedInvocations.append(roomID)
        let result = toggleResults.count == 1 ? toggleResults[0] : toggleResults.removeFirst()
        if case .success(let enabled) = result {
            cachedValues[roomID] = enabled
        }
        return result
    }

    func cachedValue(roomID: String) -> Bool? {
        cachedValues[roomID]
    }
}
