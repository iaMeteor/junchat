//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import IntentsUI
import SwiftUI

class ShareExtensionViewController: UIViewController {
    private static var targetConfiguration: Target.ConfigurationResult?
    private let appSettings: CommonSettingsProtocol = AppSettings()
    private var appHooks: AppHooks!
    
    private let keychainController = KeychainController(service: .sessions,
                                                        accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
    
    private var cancellables: Set<AnyCancellable> = []
    
    private let hostingController = UIHostingController(rootView: ShareExtensionView())
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        appHooks = AppHooks()
        appHooks.setUp()
        
        if Self.targetConfiguration == nil {
            Self.targetConfiguration = Target.shareExtension.configure(logLevel: appSettings.logLevel,
                                                                       traceLogPacks: appSettings.traceLogPacks,
                                                                       sentryURL: nil,
                                                                       rageshakeURL: appSettings.bugReportRageshakeURL,
                                                                       appHooks: appHooks)
        }
        
        addChild(hostingController)
        view.addMatchedSubview(hostingController.view)
        hostingController.didMove(toParent: self)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if let credentials = keychainController.restorationTokens().first {
            let homeserverURL = credentials.restorationToken.session.homeserverUrl
            appHooks.remoteSettingsHook.loadCache(forHomeserver: homeserverURL, applyingTo: appSettings)
        } else {
            // We should really show a different state when there isn't a logged in user, but for now this is fine.
            MXLog.error("Not logged in, launching app to show the authentication flow.")
        }
        
        Task {
            if let payload = await prepareSharePayload() {
                await self.openMainApp(payload: payload)
            }
            
            self.dismiss()
        }
    }
    
    // MARK: - Private
    
    private func prepareSharePayload() async -> ShareExtensionPayload? {
        guard let extensionContext,
              let extensionItem = extensionContext.inputItems.first as? NSExtensionItem,
              let itemProviders = extensionItem.attachments else {
            return nil
        }
        
        let roomID = (extensionContext.intent as? INSendMessageIntent)?.conversationIdentifier
        
        for itemProvider in itemProviders {
            if let url = await itemProvider.loadTransferable(type: URL.self), !url.isFileURL {
                let text = await Self.formattedShareText(for: url, extensionItem: extensionItem, itemProvider: itemProvider)
                return .text(roomID: roomID, text: text)
            }
        }
        
        for itemProvider in itemProviders {
            if let string = await itemProvider.loadString(),
               let text = Self.normalizedShareText(string) {
                return .text(roomID: roomID, text: text)
            }
        }
        
        var mediaFiles = [ShareExtensionMediaFile]()
        for itemProvider in itemProviders {
            if let fileURL = await itemProvider.storeData(withinAppGroupContainer: true) {
                mediaFiles.append(.init(url: fileURL, suggestedName: fileURL.lastPathComponent))
            } else {
                MXLog.error("Failed loading NSItemProvider data: \(itemProvider)")
            }
        }
        
        if !mediaFiles.isEmpty {
            return .mediaFiles(roomID: roomID, mediaFiles: mediaFiles)
        }
        
        return nil
    }
    
    private static func formattedShareText(for url: URL, extensionItem: NSExtensionItem, itemProvider: NSItemProvider) async -> String {
        var parts = [String]()
        appendUniqueShareText(extensionItem.attributedTitle?.string, to: &parts)
        appendUniqueShareText(extensionItem.attributedContentText?.string, to: &parts)
        await appendUniqueShareText(itemProvider.loadString(), to: &parts)
        appendUniqueShareText(url.absoluteString, to: &parts)
        return parts.joined(separator: "\n")
    }
    
    private static func appendUniqueShareText(_ value: String?, to parts: inout [String]) {
        guard let text = normalizedShareText(value),
              !parts.contains(text) else {
            return
        }
        
        parts.append(text)
    }
    
    private static func normalizedShareText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        
        let text = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        guard !text.isEmpty else {
            return nil
        }
        
        if text.count > 600 {
            return "\(text.prefix(600))..."
        }
        
        return text
    }
    
    private func openMainApp(payload: ShareExtensionPayload) async {
        guard let payload = urlEncodeSharePayload(payload) else {
            MXLog.error("Failed preparing share payload")
            return
        }
        
        guard let url = URL(string: "\(InfoPlistReader.main.baseBundleIdentifier):/\(ShareExtensionConstants.urlPath)?\(payload)") else {
            MXLog.error("Failed retrieving main application scheme")
            return
        }
        
        await openURL(url)
    }
    
    private func urlEncodeSharePayload(_ payload: ShareExtensionPayload) -> String? {
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            MXLog.error("Failed encoding share payload with error: \(error)")
            return nil
        }
        
        guard let jsonString = String(data: data, encoding: .utf8) else {
            MXLog.error("Invalid payload data")
            return nil
        }
        
        return jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
    
    private func dismiss() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    private func openURL(_ url: URL) async {
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                await application.open(url)
                return
            }
            
            responder = responder?.next
        }
    }
}
