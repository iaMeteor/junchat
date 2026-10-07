//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct CallDiagnosticEvent: Codable, Equatable {
    enum Component: String, Codable { case elementCall = "element_call", ios, android, web }
    enum Stage: String, Codable { case permission, capture, publication, signaling, connection, subscription, encryption, playback, audioRoute = "audio_route", lifecycle }
    enum Status: String, Codable { case started, succeeded, failed, retrying, stateChanged = "state_changed", ended }
    enum Code: String, Codable {
        case none, unknown, permissionDenied = "permission_denied", deviceNotFound = "device_not_found", deviceInUse = "device_in_use"
        case captureFailed = "capture_failed", publishRejected = "publish_rejected", publishTimeout = "publish_timeout", negotiationFailed = "negotiation_failed"
        case signalingFailed = "signaling_failed", transportFailed = "transport_failed", subscriptionFailed = "subscription_failed", playbackFailed = "playback_failed"
        case cleanupFailed = "cleanup_failed", cancelled, interrupted, disconnected, trackEnded = "track_ended", noMedia = "no_media", notSupported = "not_supported"
        case encryptionFailed = "encryption_failed"
    }

    enum Source: String, Codable { case microphone, camera, screenShare = "screen_share", unknown }
    enum State: String, Codable {
        case connecting, connected, reconnecting, disconnected, live, ended, muted, unmuted, active, inactive, background, foreground
        case earpiece, speaker, bluetooth, headphones, unknown
    }

    let sessionID: String
    let sequence: Int
    let occurredAt: String
    let component: Component
    let stage: Stage
    let status: Status
    let code: Code
    let source: Source
    var attempt: Int?
    var elapsedMS: Int?
    var state: State?
    var trackIDHash: String?
    var clientTrackIDHash: String?
    var participantIDHash: String?
    var rttMS: Int?
    var packetsSent: Int64?
    var packetsReceived: Int64?
    var packetsLost: Int64?
    var bytesSent: Int64?
    var bytesReceived: Int64?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id", sequence, occurredAt = "occurred_at", component, stage, status, code, source, attempt
        case elapsedMS = "elapsed_ms", state, trackIDHash = "track_id_hash", clientTrackIDHash = "client_track_id_hash"
        case participantIDHash = "participant_id_hash", rttMS = "rtt_ms", packetsSent = "packets_sent", packetsReceived = "packets_received"
        case packetsLost = "packets_lost", bytesSent = "bytes_sent", bytesReceived = "bytes_received"
    }

    static let consolePrefix = "JUNCHAT_CALL_DIAGNOSTIC "
    static let maximumRecordBytes = 4096

    static func fromConsole(_ message: String, level: String) -> Self? {
        guard level == "info", message.hasPrefix(consolePrefix),
              message.utf8.count <= maximumRecordBytes + consolePrefix.utf8.count else { return nil }
        let data = Data(message.dropFirst(consolePrefix.count).utf8)
        // Decodable alone ignores unknown keys and treats null optionals as absent.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))),
              !object.values.contains(where: { $0 is NSNull }),
              let event = try? JSONDecoder().decode(Self.self, from: data),
              event.component == .elementCall, event.isValid else { return nil }
        return event
    }

    var isValid: Bool {
        guard Self.matches(sessionID, "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"),
              UUID(uuidString: sessionID) != nil,
              (1...1_000_000).contains(sequence),
              Self.isUTCTimestamp(occurredAt),
              attempt.map({ (0...1000).contains($0) }) ?? true,
              elapsedMS.map({ (0...86_400_000).contains($0) }) ?? true,
              rttMS.map({ (0...60000).contains($0) }) ?? true else { return false }
        let hashes = [trackIDHash, clientTrackIDHash, participantIDHash].compactMap { $0 }
        let counters = [packetsSent, packetsReceived, packetsLost, bytesSent, bytesReceived].compactMap { $0 }
        return hashes.allSatisfy { Self.matches($0, "^[a-f0-9]{64}$") } &&
            counters.allSatisfy { (0...9_007_199_254_740_991).contains($0) }
    }

    static func isVersion(_ value: String) -> Bool {
        value.utf8.count <= 32 && matches(value, "^[A-Za-z0-9.+_-]+$")
    }

    private static func isUTCTimestamp(_ value: String) -> Bool {
        guard value.utf8.count <= 40,
              matches(value, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|\\+00:00)$") else { return false }
        let formatter = ISO8601DateFormatter()
        if value.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        guard let date = formatter.date(from: value) else { return false }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.string(from: date).prefix(19) == value.prefix(19)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }
}

struct CallDiagnosticEnvelope: Encodable {
    let schema = "junchat.call-diagnostics.v1"
    let platform = "ios"
    let appVersion: String
    let build: String
    let events: [CallDiagnosticEvent]

    private enum CodingKeys: String, CodingKey {
        case schema, platform, appVersion = "app_version", build, events
    }

    func encoded() -> Data? {
        guard CallDiagnosticEvent.isVersion(appVersion), CallDiagnosticEvent.isVersion(build),
              (1...64).contains(events.count), events.allSatisfy(\.isValid) else { return nil }
        let identifiers = events.map { "\($0.sessionID.lowercased()):\($0.sequence)" }
        guard Set(identifiers).count == events.count else { return nil }
        return try? JSONEncoder().encode(self)
    }
}
