// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
internal enum UntranslatedL10n {
  /// Select message
  internal static var a11yMessageSelectionLabel: String { return UntranslatedL10n.tr("Untranslated", "a11y_message_selection_label") }
  /// Not selected
  internal static var a11yMessageSelectionNotSelected: String { return UntranslatedL10n.tr("Untranslated", "a11y_message_selection_not_selected") }
  /// Selected
  internal static var a11yMessageSelectionSelected: String { return UntranslatedL10n.tr("Untranslated", "a11y_message_selection_selected") }
  /// Mark all as read
  internal static var actionMarkAllAsRead: String { return UntranslatedL10n.tr("Untranslated", "action_mark_all_as_read") }
  /// Select messages
  internal static var actionSelectMessages: String { return UntranslatedL10n.tr("Untranslated", "action_select_messages") }
  /// Show as card
  internal static var actionShowLinkAsCard: String { return UntranslatedL10n.tr("Untranslated", "action_show_link_as_card") }
  /// Show as normal link
  internal static var actionShowLinkAsText: String { return UntranslatedL10n.tr("Untranslated", "action_show_link_as_text") }
  /// You currently don’t have any chats with these contacts. Confirm inviting them to this room before continuing.
  internal static var cryptoHistorySharingConfirmInviteDialogContent: String { return UntranslatedL10n.tr("Untranslated", "crypto_history_sharing_confirm_invite_dialog_content") }
  /// Invite new contacts to this room?
  internal static var cryptoHistorySharingConfirmInviteDialogTitle: String { return UntranslatedL10n.tr("Untranslated", "crypto_history_sharing_confirm_invite_dialog_title") }
  /// You currently don’t have any chats with this person. Confirm inviting them before continuing.
  internal static var cryptoHistorySharingConfirmStartChatDialogContent: String { return UntranslatedL10n.tr("Untranslated", "crypto_history_sharing_confirm_start_chat_dialog_content") }
  /// Start a chat with this new contact?
  internal static var cryptoHistorySharingConfirmStartChatDialogTitle: String { return UntranslatedL10n.tr("Untranslated", "crypto_history_sharing_confirm_start_chat_dialog_title") }
  /// Don’t show again
  internal static var identityConfirmationDontShowAgain: String { return UntranslatedL10n.tr("Untranslated", "identity_confirmation_dont_show_again") }
  /// Card
  internal static var linkPresentationCard: String { return UntranslatedL10n.tr("Untranslated", "link_presentation_card") }
  /// Link display
  internal static var linkPresentationPickerTitle: String { return UntranslatedL10n.tr("Untranslated", "link_presentation_picker_title") }
  /// Plain text
  internal static var linkPresentationText: String { return UntranslatedL10n.tr("Untranslated", "link_presentation_text") }
  /// Added to send queue
  internal static var screenMessageForwardingAddedToSendQueue: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_added_to_send_queue") }
  /// Adding
  internal static var screenMessageForwardingAdding: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_adding") }
  /// Adding to send queue
  internal static var screenMessageForwardingAddingToSendQueue: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_adding_to_send_queue") }
  /// Plural format key: "%#@VARIABLE@"
  internal static func screenMessageForwardingCancelledPartial(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_cancelled_partial", p1)
  }
  /// Cancelling forwarding
  internal static var screenMessageForwardingCancelling: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_cancelling") }
  /// No more messages can be forwarded safely because too many unresolved forwards are saved. Check earlier destinations and resolve an uncertain forward before trying again.
  internal static var screenMessageForwardingCapacityExceeded: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_capacity_exceeded") }
  /// Continue without resending
  internal static var screenMessageForwardingContinueWithoutResending: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_continue_without_resending") }
  /// Some messages may already be in the send queue
  internal static var screenMessageForwardingOutcomeUnknown: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_outcome_unknown") }
  /// %1$d of %2$d
  internal static func screenMessageForwardingProgressAccessibilityValue(_ p1: Int, _ p2: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_progress_accessibility_value", p1, p2)
  }
  /// Some messages weren't added to the send queue
  internal static var screenMessageForwardingQueueFailed: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_queue_failed") }
  /// To avoid duplicates, Junchat won't send them again automatically. Continue without resending, or send them again only after checking the destination.
  internal static var screenMessageForwardingResolutionMessage: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_resolution_message") }
  /// Forwarding outcome unknown
  internal static var screenMessageForwardingResolutionTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_resolution_title") }
  /// Review
  internal static var screenMessageForwardingReview: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_review") }
  /// Send again
  internal static var screenMessageForwardingSendAgain: String { return UntranslatedL10n.tr("Untranslated", "screen_message_forwarding_send_again") }
  /// Some selected messages are no longer available. Select them again and try forwarding.
  internal static var screenRoomMessageSelectionChangedError: String { return UntranslatedL10n.tr("Untranslated", "screen_room_message_selection_changed_error") }
  /// Plural format key: "%#@VARIABLE@"
  internal static func screenRoomMessageSelectionDeleteConfirmation(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_room_message_selection_delete_confirmation", p1)
  }
  /// Delete messages?
  internal static var screenRoomMessageSelectionDeleteConfirmationTitle: String { return UntranslatedL10n.tr("Untranslated", "screen_room_message_selection_delete_confirmation_title") }
  /// Plural format key: "%#@VARIABLE@"
  internal static func screenRoomMessageSelectionSelectedCount(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "screen_room_message_selection_selected_count", p1)
  }
  /// This sends read receipts and may start message expiry timers. Pending invitations will remain.
  internal static var screenRoomlistMarkAllAsReadDialogContent: String { return UntranslatedL10n.tr("Untranslated", "screen_roomlist_mark_all_as_read_dialog_content") }
  /// All chats marked as read
  internal static var screenRoomlistMarkAllAsReadSuccess: String { return UntranslatedL10n.tr("Untranslated", "screen_roomlist_mark_all_as_read_success") }
  /// Clear all data currently stored on this device?
  /// Sign in again to access your account data and messages.
  internal static var softLogoutClearDataDialogContent: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_dialog_content") }
  /// Clear data
  internal static var softLogoutClearDataDialogTitle: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_dialog_title") }
  /// Warning: Your personal data (including encryption keys) is still stored on this device.
  /// 
  /// Clear it if you’re finished using this device, or want to sign in to another account.
  internal static var softLogoutClearDataNotice: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_notice") }
  /// Clear all data
  internal static var softLogoutClearDataSubmit: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_submit") }
  /// Clear personal data
  internal static var softLogoutClearDataTitle: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_clear_data_title") }
  /// Sign in to recover encryption keys stored exclusively on this device. You need them to read all of your secure messages on any device.
  internal static var softLogoutSigninE2eWarningNotice: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_signin_e2e_warning_notice") }
  /// Your homeserver (%1$s) admin has signed you out of your account %2$s (%3$s).
  internal static func softLogoutSigninNotice(_ p1: UnsafePointer<CChar>, _ p2: UnsafePointer<CChar>, _ p3: UnsafePointer<CChar>) -> String {
    return UntranslatedL10n.tr("Untranslated", "soft_logout_signin_notice", p1, p2, p3)
  }
  /// Sign in
  internal static var softLogoutSigninTitle: String { return UntranslatedL10n.tr("Untranslated", "soft_logout_signin_title") }
  /// Untranslated
  internal static var untranslated: String { return UntranslatedL10n.tr("Untranslated", "untranslated") }
  /// Plural format key: "%#@VARIABLE@"
  internal static func untranslatedPlural(_ p1: Int) -> String {
    return UntranslatedL10n.tr("Untranslated", "untranslated_plural", p1)
  }
}
// swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

// MARK: - Implementation Details

extension UntranslatedL10n {
  static func tr(_ table: String, _ key: String, _ args: CVarArg...) -> String {
    let language = Bundle.junchatPreferredLocalizations.first ?? Bundle.junchatSimplifiedChineseLocalization
    guard let bundle = Bundle.lprojBundle(for: language) ?? Bundle.lprojBundle(for: Bundle.junchatSimplifiedChineseLocalization) else { return key }
#if DEBUG
    if UserDefaults.standard.bool(forKey: "NSDoubleLocalizedStrings"),
       let translation = doubleLocalizedPlural(table: table, key: key, arguments: args, language: language, bundle: bundle) {
      return "\(translation) \(translation)"
    }
#endif
    let format = NSLocalizedString(key, tableName: table, bundle: bundle, comment: "")
    return String(format: format, locale: Locale(identifier: language), arguments: args)
  }

#if DEBUG
  private static func doubleLocalizedPlural(table: String,
                                            key: String,
                                            arguments: [CVarArg],
                                            language: String,
                                            bundle: Bundle) -> String? {
    guard arguments.count == 1,
          let count = arguments.first as? Int,
          let url = bundle.url(forResource: table, withExtension: "stringsdict"),
          let data = try? Data(contentsOf: url),
          let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let entry = strings[key] as? [String: Any],
          let plural = entry.values
            .compactMap({ $0 as? [String: String] })
            .first(where: { $0["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType" }),
          let format = count == 1 ? plural["one"] ?? plural["other"] : plural["other"] else {
      return nil
    }
    return String(format: format, locale: Locale(identifier: language), arguments: arguments)
  }
#endif
}

// swiftlint:enable all
