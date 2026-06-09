//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation

final class CallAudioSessionController {
    private let audioSession: AudioSessionProtocol
    private var hasPreparedForCall = false

    init(audioSession: AudioSessionProtocol = AVAudioSession.sharedInstance()) {
        self.audioSession = audioSession
    }

    func activateForCall() {
        do {
            // Element Call runs WebRTC inside WebKit. Let WebKit own the active
            // PlayAndRecord/VoiceChat session; the native shell only prepares
            // system behavior and applies route overrides.
            try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
            hasPreparedForCall = true
        } catch {
            MXLog.error("Failed preparing call audio session: \(error)")
        }
    }

    func deactivateAfterCall() {
        do {
            try audioSession.overrideOutputAudioPort(.none)
            hasPreparedForCall = false
        } catch {
            MXLog.error("Failed clearing call audio route override: \(error)")
        }
    }

    func routeAudioToNativeEarpiece() {
        do {
            try audioSession.overrideOutputAudioPort(.none)
            hasPreparedForCall = true
        } catch {
            MXLog.error("Failed routing call audio to native earpiece: \(error)")
        }
    }

    func routeAudioToSpeaker() {
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
            hasPreparedForCall = true
        } catch {
            MXLog.error("Failed routing call audio to speaker: \(error)")
        }
    }

    func handleInterruption(notification: Notification) {
        guard hasPreparedForCall,
              let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .ended else {
            return
        }
    }

    func handleMediaServicesReset() {
        guard hasPreparedForCall else {
            return
        }
    }
}
