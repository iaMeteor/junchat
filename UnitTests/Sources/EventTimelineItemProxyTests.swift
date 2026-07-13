//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import Testing

@MainActor
struct EventTimelineItemProxyTests {
    @Test
    func encryptedEnvelopeWithMarkedUnsignedIsPrivacyControlled() {
        let proxy = makeMessageProxy(latestJSON: Self.encryptedMarkedEventJSON)

        #expect(proxy.isPrivacyControlled)
    }

    @Test
    func decryptedEventWithCopiedMarkedUnsignedIsPrivacyControlled() {
        let proxy = makeMessageProxy(latestJSON: Self.decryptedMarkedEventJSON)

        #expect(proxy.isPrivacyControlled)
    }

    @Test
    func normalizedUnsignedKeepsMarkedOriginalMarkedAfterUnmarkedEdit() {
        let proxy = makeMessageProxy(latestJSON: """
        {
          "content": {
            "m.new_content": {
              "com.heyujk.junchat.privacy_mode": false,
              "com.heyujk.junchat.privacy_mode.read_based": false
            },
            "m.relates_to": { "rel_type": "m.replace", "event_id": "$original" }
          },
          "unsigned": {
            "com.heyujk.junchat.privacy_mode": true,
            "com.heyujk.junchat.privacy_mode.read_based": true
          }
        }
        """)

        #expect(proxy.isPrivacyControlled)
    }

    @Test
    func normalizedUnsignedKeepsUnmarkedOriginalUnmarkedAfterMarkedEdit() {
        let proxy = makeMessageProxy(latestJSON: """
        {
          "content": {
            "m.new_content": {
              "com.heyujk.junchat.privacy_mode": true,
              "com.heyujk.junchat.privacy_mode.read_based": true
            },
            "m.relates_to": { "rel_type": "m.replace", "event_id": "$original" }
          },
          "unsigned": {
            "com.heyujk.junchat.privacy_mode": false,
            "com.heyujk.junchat.privacy_mode.read_based": false
          }
        }
        """)

        #expect(!proxy.isPrivacyControlled)
    }

    @Test
    func contentMarkersWithoutUnsignedAreIgnored() {
        let proxy = makeMessageProxy(latestJSON: """
        {
          "content": {
            "com.heyujk.junchat.privacy_mode": true,
            "com.heyujk.junchat.privacy_mode.read_based": true
          }
        }
        """)

        #expect(!proxy.isPrivacyControlled)
    }

    @Test
    func markersRequireStrictTrueBooleans() {
        let rejectedJSON = [
            unsignedJSON(privacyMode: "1", readBased: "true"),
            unsignedJSON(privacyMode: "\"true\"", readBased: "true"),
            unsignedJSON(privacyMode: "null", readBased: "true"),
            unsignedJSON(privacyMode: "false", readBased: "true"),
            unsignedJSON(privacyMode: "true", readBased: "1"),
            unsignedJSON(privacyMode: "true", readBased: "\"true\""),
            unsignedJSON(privacyMode: "true", readBased: "null"),
            unsignedJSON(privacyMode: "true", readBased: "false"),
            "{ \"unsigned\": { \"com.heyujk.junchat.privacy_mode\": true } }",
            "{ \"unsigned\": { \"com.heyujk.junchat.privacy_mode.read_based\": true } }",
            "{ \"unsigned\": {} }"
        ]

        for json in rejectedJSON {
            #expect(!makeMessageProxy(latestJSON: json).isPrivacyControlled)
        }
    }

    @Test
    func malformedAndNonObjectJSONIsNotPrivacyControlled() {
        for json in ["{", "[]", "null", "{}", "{ \"unsigned\": null }", "{ \"unsigned\": [] }", "{ \"unsigned\": \"marked\" }"] {
            #expect(!makeMessageProxy(latestJSON: json).isPrivacyControlled)
        }
    }

    @Test
    func localEchoIsNotPrivacyControlled() {
        let proxy = makeMessageProxy(latestJSON: Self.decryptedMarkedEventJSON, isRemote: false)

        #expect(!proxy.isPrivacyControlled)
    }

    @Test
    func localEchoWithAssignedEventIDIsNotPrivacyControlled() {
        let proxy = makeMessageProxy(latestJSON: Self.decryptedMarkedEventJSON,
                                     isRemote: false,
                                     eventOrTransactionID: .eventId(eventId: "$assigned"))

        #expect(!proxy.isPrivacyControlled)
    }

    @Test
    func redactedEventWithClearedLatestJSONIsNotPrivacyControlled() {
        let item = EventTimelineItem(configuration: .init(latestJSON: nil))
        let proxy = EventTimelineItemProxy(item: item, uniqueID: .init("redacted"))

        #expect(!proxy.isPrivacyControlled)
    }

    @Test
    func missingLatestJSONIsNotPrivacyControlled() {
        let proxy = makeMessageProxy(latestJSON: nil)

        #expect(!proxy.isPrivacyControlled)
    }

    private func makeMessageProxy(latestJSON: String?,
                                  isRemote: Bool = true,
                                  eventOrTransactionID: EventOrTransactionId? = nil) -> EventTimelineItemProxy {
        let item = EventTimelineItem.mockMessage(configuration: .init(isRemote: isRemote,
                                                                      eventOrTransactionID: eventOrTransactionID,
                                                                      latestJSON: latestJSON))
        return EventTimelineItemProxy(item: item, uniqueID: .init("event"))
    }

    private func unsignedJSON(privacyMode: String, readBased: String) -> String {
        """
        {
          "unsigned": {
            "com.heyujk.junchat.privacy_mode": \(privacyMode),
            "com.heyujk.junchat.privacy_mode.read_based": \(readBased)
          }
        }
        """
    }

    private static let encryptedMarkedEventJSON = """
    {
      "type": "m.room.encrypted",
      "content": {
        "algorithm": "m.megolm.v1.aes-sha2",
        "ciphertext": "ciphertext",
        "session_id": "session"
      },
      "unsigned": {
        "com.heyujk.junchat.privacy_mode": true,
        "com.heyujk.junchat.privacy_mode.read_based": true
      }
    }
    """

    private static let decryptedMarkedEventJSON = """
    {
      "type": "m.room.message",
      "content": { "msgtype": "m.text", "body": "secret" },
      "unsigned": {
        "com.heyujk.junchat.privacy_mode": true,
        "com.heyujk.junchat.privacy_mode.read_based": true
      }
    }
    """
}
