//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
// Copyright 2021-2025 The Matrix.org Foundation C.I.C
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK
#if IS_MAIN_APP
import UIKit
#endif

/// Logging utility that provies multiple logging levels as well as file output and rolling.
/// Its purpose is to provide a common entry for customizing logging and should be used throughout the code.
enum MXLog {
    private nonisolated(unsafe) static var rootSpan: Span!
    private nonisolated(unsafe) static var currentTarget: String!
    
    static func configure(currentTarget: String) {
        self.currentTarget = currentTarget
        
        rootSpan = Span(file: #file, line: #line, level: .info, target: self.currentTarget, name: "root", bridgeTraceId: nil)
        rootSpan.enter()
    }
    
    static func createSpan(_ name: String,
                           file: String = #file,
                           function: String = #function,
                           line: Int = #line,
                           column: Int = #column) -> Span {
        createSpan(name, level: .info, file: file, function: function, line: line, column: column)
    }
    
    static func verbose(_ message: Any,
                        file: String = #file,
                        function: String = #function,
                        line: Int = #line,
                        column: Int = #column) {
        log(message, level: .trace, file: file, function: function, line: line, column: column)
    }
    
    static func debug(_ message: Any,
                      file: String = #file,
                      function: String = #function,
                      line: Int = #line,
                      column: Int = #column) {
        log(message, level: .debug, file: file, function: function, line: line, column: column)
    }
    
    static func info(_ message: Any,
                     file: String = #file,
                     function: String = #function,
                     line: Int = #line,
                     column: Int = #column) {
        log(message, level: .info, file: file, function: function, line: line, column: column)
    }
    
    static func warning(_ message: Any,
                        file: String = #file,
                        function: String = #function,
                        line: Int = #line,
                        column: Int = #column) {
        log(message, level: .warn, file: file, function: function, line: line, column: column)
    }
    
    /// Log error.
    ///
    /// - Parameters:
    ///     - message: Description of the error without any variables (this is to improve error aggregations by type)
    static func error(_ message: Any,
                      file: String = #file,
                      function: String = #function,
                      line: Int = #line,
                      column: Int = #column) {
        log(message, level: .error, file: file, function: function, line: line, column: column)
    }
    
    /// Log failure.
    ///
    /// A failure is any type of programming error which should never occur in production. In `DEBUG` configuration
    /// any failure will raise `assertionFailure`
    ///
    /// - Parameters:
    ///     - message: Description of the error without any variables (this is to improve error aggregations by type)
    static func failure(_ message: Any,
                        file: String = #file,
                        function: String = #function,
                        line: Int = #line,
                        column: Int = #column) {
        log(message, level: .error, file: file, function: function, line: line, column: column)
        
        #if DEBUG
        assertionFailure("\(message)")
        #endif
    }
    
    #if DEBUG
    private static let devPrefix = URL.documentsDirectory.pathComponents[2].uppercased()
    /// A helper method for print debugging, only available on debug builds.
    ///
    /// When running on the simulator this will log `[USERNAME] message` so that
    /// you can easily filter the Xcode console to see only the logs you're interested in.
    static func dev(_ message: Any,
                    file: String = #file,
                    function: String = #function,
                    line: Int = #line,
                    column: Int = #column) {
        log("[\(devPrefix)] \(message)", level: .info, file: file, function: function, line: line, column: column)
    }
    #endif
    
    // MARK: - Private
    
    // periphery:ignore:parameters function,column
    private static func createSpan(_ name: String,
                                   level: LogLevel,
                                   file: String = #file,
                                   function: String = #function,
                                   line: Int = #line,
                                   column: Int = #column) -> Span {
        if Span.current().isNone() {
            rootSpan.enter()
        }
        
        return Span(file: file, line: UInt32(line), level: level.rustLogLevel, target: currentTarget, name: name, bridgeTraceId: nil)
    }
    
    // periphery:ignore:parameters function,column
    private static func log(_ message: Any,
                            level: LogLevel,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line,
                            column: Int = #column) {
        guard let rootSpan else {
            return
        }
        
        if Span.current().isNone() {
            rootSpan.enter()
        }
        
        logEvent(file: (file as NSString).lastPathComponent, line: UInt32(line), level: level.rustLogLevel, target: currentTarget, message: "\(message)")
        #if IS_MAIN_APP && !JUNCHAT_CANARY
        if level == .error {
            JunchatErrorReporter.captureError(message, file: file, function: function, line: line)
        }
        #endif
    }
}

#if IS_MAIN_APP
#if JUNCHAT_CANARY
enum JunchatErrorReporter {
    static func install() {
        // Canary diagnostics require a separately provisioned credential.
    }

    static func setUploader(_ uploader: JunchatDiagnosticsUploading?) { }
}
#else
enum JunchatErrorReporter {
    private static let queue = DispatchQueue(label: "cn.yyzs120.junchat.error-reporter")
    private static let duplicateWindow: TimeInterval = 60
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var uploader: JunchatDiagnosticsUploading?
    private nonisolated(unsafe) static var recentReports = [String: Date]()
    
    static func install() {
        queue.async {
            guard !installed else { return }
            installed = true
            if uploader != nil {
                uploadPendingCrashMarkers()
            }
            NSSetUncaughtExceptionHandler { exception in
                JunchatErrorReporter.persistCrashMarker(exception)
            }
        }
    }

    static func setUploader(_ uploader: JunchatDiagnosticsUploading?) {
        queue.async {
            self.uploader = uploader
            if installed, uploader != nil {
                uploadPendingCrashMarkers()
            }
        }
    }
    
    static func captureError(_ message: Any,
                             file: String,
                             function: String,
                             line: Int,
                             category: String = "ios-log",
                             name: String = "MXLogError",
                             context: [String: Any] = [:]) {
        queue.async {
            guard installed else { return }
            var mergedContext = context
            mergedContext["file"] = (file as NSString).lastPathComponent
            mergedContext["function"] = function
            mergedContext["line"] = line
            let payload = buildPayload(severity: "error",
                                       category: category,
                                       name: name,
                                       message: "\(message)",
                                       stack: Thread.callStackSymbols.joined(separator: "\n"),
                                       context: mergedContext)
            guard !isDuplicate(payload) else { return }
            upload(payload)
        }
    }
    
    private static func persistCrashMarker(_ exception: NSException) {
        let payload = buildPayload(severity: "fatal",
                                   category: "ios-crash",
                                   name: exception.name.rawValue,
                                   message: exception.reason ?? "Uncaught NSException",
                                   stack: exception.callStackSymbols.joined(separator: "\n"),
                                   context: ["exception": exception.name.rawValue])
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: pendingCrashFile) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(to: pendingCrashFile, atomically: true, encoding: .utf8)
        }
    }
    
    private static func uploadPendingCrashMarkers() {
        guard let text = try? String(contentsOf: pendingCrashFile, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else {
            try? FileManager.default.removeItem(at: pendingCrashFile)
            return
        }
        var uploadedAll = true
        let group = DispatchGroup()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            group.enter()
            upload(payload) { success in
                uploadedAll = uploadedAll && success
                group.leave()
            }
        }
        group.notify(queue: queue) {
            if uploadedAll {
                try? FileManager.default.removeItem(at: pendingCrashFile)
            }
        }
    }
    
    private static func buildPayload(severity: String,
                                     category: String,
                                     name: String,
                                     message: String,
                                     stack: String,
                                     context: [String: Any]) -> [String: Any] {
        var sanitizedContext = [String: Any]()
        for (key, value) in context.prefix(40) where !looksSensitive(key) {
            sanitizedContext[sanitize(key, max: 80)] = sanitize("\(value)", max: 500)
        }
        return [
            "platform": "ios",
            "app_version": InfoPlistReader.main.bundleShortVersionString,
            "build": InfoPlistReader.main.bundleVersion,
            "os_version": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "device_model": deviceModel,
            "severity": severity,
            "category": sanitize(category, max: 80),
            "name": sanitize(name, max: 120),
            "message": sanitize(message, max: 2000),
            "stack": sanitize(stack, max: 12000),
            "occurred_at": ISO8601DateFormatter().string(from: Date()),
            "context": sanitizedContext
        ]
    }
    
    private static func upload(_ payload: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let uploader else {
            completion?(false)
            return
        }
        Task {
            let result = await uploader.upload(body)
            queue.async {
                switch result {
                case .success:
                    completion?(true)
                case .failure:
                    completion?(false)
                }
            }
        }
    }
    
    private static func isDuplicate(_ payload: [String: Any]) -> Bool {
        let key = [
            payload["platform"] as? String,
            payload["category"] as? String,
            payload["name"] as? String,
            payload["message"] as? String
        ].compactMap { $0 }.joined(separator: "|")
        let now = Date()
        let last = recentReports[key]
        recentReports[key] = now
        if recentReports.count > 120 {
            recentReports = recentReports.filter { now.timeIntervalSince($0.value) < 300 }
        }
        return last.map { now.timeIntervalSince($0) < duplicateWindow } ?? false
    }
    
    private static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "JunchatErrors", directoryHint: .isDirectory)
    }
    
    private static var pendingCrashFile: URL {
        storageDirectory.appending(path: "pending-crashes.jsonl")
    }
    
    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
    
    private static func sanitize(_ value: String, max: Int) -> String {
        var sanitized = value
        let replacements = [
            #"(?i)authorization\s*[:=]\s*Bearer\s+\S+"#,
            #"(?i)(access[_-]?token|refresh[_-]?token|password|secret|api[_-]?key)\s*[:=]\s*\S+"#,
            #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]{12,}"#
        ]
        for pattern in replacements {
            sanitized = sanitized.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.count > max {
            sanitized = String(sanitized.prefix(max)) + "..."
        }
        return sanitized
    }
    
    private static func looksSensitive(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("token") ||
            lower.contains("authorization") ||
            lower.contains("password") ||
            lower.contains("secret") ||
            lower.contains("cookie") ||
            lower.contains("key")
    }
}
#endif
#endif
