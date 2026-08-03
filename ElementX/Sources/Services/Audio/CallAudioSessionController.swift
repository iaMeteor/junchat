//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation

final class CallAudioSessionController {
    private let audioSession: AudioSessionProtocol
    private var preparedVoiceOnly: Bool?

    init(audioSession: AudioSessionProtocol = AVAudioSession.sharedInstance()) {
        self.audioSession = audioSession
    }

    func activateForCall(voiceOnly: Bool) {
        guard preparedVoiceOnly != voiceOnly else { return }

        do {
            let mode = voiceOnly ? AVAudioSession.Mode.voiceChat : .videoChat
            let options: AVAudioSession.CategoryOptions = voiceOnly
                ? [.allowBluetoothHFP]
                : [.allowBluetoothHFP, .defaultToSpeaker]

            // Configure before WebKit starts media capture. Do not activate the
            // session here; WebKit owns outgoing media after incoming CallKit
            // audio ownership has been released.
            try audioSession.setCategory(.playAndRecord, mode: mode, options: options)
            try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
            preparedVoiceOnly = voiceOnly
        } catch {
            MXLog.error("Failed preparing call audio session: \(error)")
        }
    }

    func deactivateAfterCall() {
        preparedVoiceOnly = nil
        do {
            try audioSession.overrideOutputAudioPort(.none)
        } catch {
            MXLog.error("Failed clearing call audio route override: \(error)")
        }
    }

    func routeAudioToNativeEarpiece() {
        do {
            try audioSession.overrideOutputAudioPort(.none)
        } catch {
            MXLog.error("Failed routing call audio to native earpiece: \(error)")
        }
    }

    func routeAudioToSpeaker() {
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
        } catch {
            MXLog.error("Failed routing call audio to speaker: \(error)")
        }
    }

    func handleInterruption(notification: Notification) {
        guard preparedVoiceOnly != nil,
              let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .ended else {
            return
        }
        // WebKit owns the active WebRTC session; lifecycle recovery is handled by CallScreenViewModel.
    }

    func handleMediaServicesReset() {
        preparedVoiceOnly = nil
    }
}
