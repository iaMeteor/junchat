/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import CryptoKit
import Darwin
import Foundation

enum ElementCallCandidateGitCheckout {
    private struct TreeEntry {
        let mode: String
        let objectID: String
        let path: String

        var isSubmodule: Bool {
            mode == "160000"
        }
    }

    private static let maximumCheckoutFiles = 100_000
    private static let maximumCheckoutBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let maximumGitMetadataEntries = 1_000_000
    private static let maximumAlternateObjectStores = 64
    private static let maximumSubmoduleDepth = 16

    static func validate(checkoutURL: URL,
                         revision: String,
                         sourcePackagesRootURL: URL) throws {
        try validate(checkoutURL: checkoutURL,
                     revision: revision,
                     sourcePackagesRootURL: sourcePackagesRootURL,
                     depth: 0)
    }

    static func rebaseAlternates(checkoutURL: URL,
                                 sourceRootURL: URL,
                                 stagedRootURL: URL) throws {
        var rebasedObjectStores = Set<String>()
        try rebaseAlternates(checkoutURL: checkoutURL,
                             sourceRootURL: sourceRootURL,
                             stagedRootURL: stagedRootURL,
                             rebasedObjectStores: &rebasedObjectStores,
                             depth: 0)
    }

    private static func validate(checkoutURL: URL,
                                 revision: String,
                                 sourcePackagesRootURL: URL,
                                 depth: Int) throws {
        try require(depth <= maximumSubmoduleDepth,
                    "SourcePackages submodules exceed the supported verification depth.")
        let head = try gitString(["-C", checkoutURL.path, "rev-parse", "--verify", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(head == revision, "A SourcePackages checkout HEAD differs from its locked revision.")
        let gitDirectoryURL = try validatedGitDirectory(checkoutURL: checkoutURL,
                                                        sourcePackagesRootURL: sourcePackagesRootURL)
        try validateLocalConfiguration(checkoutURL: checkoutURL,
                                       gitDirectoryURL: gitDirectoryURL,
                                       topLevel: depth == 0)
        var validatedObjectStores = Set<String>()
        try validateObjectStore(gitDirectoryURL.appending(path: "objects"),
                                sourcePackagesRootURL: sourcePackagesRootURL,
                                validatedObjectStores: &validatedObjectStores,
                                depth: 0)

        let entries = try treeEntries(checkoutURL: checkoutURL, revision: revision)
        try require(!entries.isEmpty && entries.count <= maximumCheckoutFiles,
                    "A SourcePackages checkout has an unsupported Git tree size.")
        let entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        try require(entriesByPath.count == entries.count,
                    "A SourcePackages checkout Git tree contains duplicate paths.")
        var allowedDirectories = Set<String>()
        for entry in entries {
            var components = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            components.removeLast()
            while !components.isEmpty {
                allowedDirectories.insert(components.joined(separator: "/"))
                components.removeLast()
            }
        }

        var seen = Set<String>()
        var totalBytes: Int64 = 0
        func visit(_ directoryURL: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [])
                .sorted { utf8Less($0.lastPathComponent, $1.lastPathComponent) }
            for childURL in children {
                let path = prefix.isEmpty ? childURL.lastPathComponent : "\(prefix)/\(childURL.lastPathComponent)"
                if prefix.isEmpty, path == ".git" {
                    continue
                }
                try ElementCallCandidatePath.validateRelative(path)
                var information = stat()
                try require(lstat(childURL.path, &information) == 0,
                            "A SourcePackages checkout changed during byte verification.")
                let type = information.st_mode & S_IFMT

                if let entry = entriesByPath[path], entry.isSubmodule {
                    try require(type == S_IFDIR && seen.insert(path).inserted,
                                "A SourcePackages submodule checkout is invalid.")
                    try validate(checkoutURL: childURL,
                                 revision: entry.objectID,
                                 sourcePackagesRootURL: sourcePackagesRootURL,
                                 depth: depth + 1)
                    continue
                }
                if type == S_IFDIR {
                    if !allowedDirectories.contains(path) {
                        try require(isEmptySwiftPMWorkspaceScaffolding(childURL),
                                    "A SourcePackages checkout contains an untracked directory: \(path).")
                        continue
                    }
                    try visit(childURL, prefix: path)
                    continue
                }

                guard let entry = entriesByPath[path], !entry.isSubmodule, seen.insert(path).inserted else {
                    throw ElementCallCandidateError.validation("A SourcePackages checkout contains an untracked entry: \(path).")
                }
                let bytes: Int64
                switch entry.mode {
                case "100644", "100755":
                    try require(type == S_IFREG && (entry.mode == "100755") == (information.st_mode & 0o111 != 0),
                                "A SourcePackages checkout file mode differs from its Git tree: \(path).")
                    bytes = information.st_size
                case "120000":
                    try require(type == S_IFLNK,
                                "A SourcePackages checkout symlink differs from its Git tree: \(path).")
                    bytes = try Int64(FileManager.default.destinationOfSymbolicLink(atPath: childURL.path).utf8.count)
                    try ElementCallCandidatePath.validateSymlink(childURL, beneath: checkoutURL,
                                                                 label: "SourcePackages checkout symlink \(path)")
                default:
                    throw ElementCallCandidateError.validation("A SourcePackages checkout contains an unsupported Git mode: \(entry.mode).")
                }
                try require(bytes >= 0 && totalBytes <= maximumCheckoutBytes - bytes,
                            "A SourcePackages checkout exceeds the supported byte size.")
                totalBytes += bytes
                let rawBlobID = try gitBlobID(url: childURL, mode: entry.mode, byteCount: bytes)
                let matchesTree: Bool
                if rawBlobID == entry.objectID {
                    matchesTree = true
                } else if entry.mode != "120000" {
                    matchesTree = try matchesFilteredWorktreeBytes(checkoutURL: checkoutURL,
                                                                   fileURL: childURL,
                                                                   path: path,
                                                                   objectID: entry.objectID,
                                                                   byteCount: bytes)
                } else {
                    matchesTree = false
                }
                try require(matchesTree,
                            "A SourcePackages checkout file differs byte-for-byte from its locked Git tree: \(path).")
            }
        }
        try visit(checkoutURL, prefix: "")
        try require(seen == Set(entries.map(\.path)),
                    "A SourcePackages checkout is missing a locked Git tree entry.")
    }

    private static func isEmptySwiftPMWorkspaceScaffolding(_ directoryURL: URL) throws -> Bool {
        guard directoryURL.lastPathComponent == ".swiftpm" else { return false }
        let children = try FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [])
        guard children.count == 1, children[0].lastPathComponent == "xcode" else { return false }
        var information = stat()
        try require(lstat(children[0].path, &information) == 0,
                    "A SourcePackages SwiftPM workspace directory changed during validation.")
        guard information.st_mode & S_IFMT == S_IFDIR else { return false }
        return try FileManager.default.contentsOfDirectory(atPath: children[0].path).isEmpty
    }

    private static func treeEntries(checkoutURL: URL, revision: String) throws -> [TreeEntry] {
        let data = try gitData(["-C", checkoutURL.path, "ls-tree", "-r", "-z", "--full-tree", revision])
        return try data.split(separator: 0, omittingEmptySubsequences: true).map { record in
            guard let separator = record.firstIndex(of: 0x09), separator < record.endIndex,
                  let header = String(data: Data(record[..<separator]), encoding: .utf8),
                  let path = String(data: Data(record[record.index(after: separator)...]), encoding: .utf8) else {
                throw ElementCallCandidateError.validation("A SourcePackages Git tree record is invalid.")
            }
            let fields = header.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            try require(fields.count == 3 &&
                ((fields[1] == "blob" && ["100644", "100755", "120000"].contains(fields[0])) ||
                    (fields[1] == "commit" && fields[0] == "160000")) &&
                ElementCallCandidateRequest.isLowercaseHex(fields[2], count: 40),
                "A SourcePackages Git tree record has unsupported fields.")
            try ElementCallCandidatePath.validateRelative(path)
            return TreeEntry(mode: fields[0], objectID: fields[2], path: path)
        }
    }

    private static func validatedGitDirectory(checkoutURL: URL,
                                              sourcePackagesRootURL: URL) throws -> URL {
        let value = try gitString(["-C", checkoutURL.path, "rev-parse", "--absolute-git-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try ElementCallCandidatePath.validateRecordedAbsolute(value, label: "SourcePackages Git directory")
        _ = try relativePath(value, beneath: sourcePackagesRootURL)
        let gitDirectoryURL = try ElementCallCandidatePath.validateExisting(URL(filePath: value), kind: .directory,
                                                                            label: "SourcePackages Git directory")
        for (path, kind, label) in [
            ("config", ElementCallCandidatePath.Kind.file, "SourcePackages Git config"),
            ("HEAD", ElementCallCandidatePath.Kind.file, "SourcePackages Git HEAD"),
            ("objects", ElementCallCandidatePath.Kind.directory, "SourcePackages Git object directory")
        ] {
            _ = try ElementCallCandidatePath.validateExisting(gitDirectoryURL.appending(path: path), kind: kind,
                                                              label: label)
        }
        var commonDirectoryInformation = stat()
        let commonDirectoryURL = gitDirectoryURL.appending(path: "commondir")
        let commonDirectoryResult = lstat(commonDirectoryURL.path, &commonDirectoryInformation)
        try require(commonDirectoryResult != 0 && errno == ENOENT,
                    "A SourcePackages checkout cannot redirect its Git common directory.")
        var worktreeConfigInformation = stat()
        let worktreeConfigURL = gitDirectoryURL.appending(path: "config.worktree")
        let worktreeConfigResult = lstat(worktreeConfigURL.path, &worktreeConfigInformation)
        try require(worktreeConfigResult != 0 && errno == ENOENT,
                    "A SourcePackages checkout cannot use per-worktree Git configuration.")
        try validateGitMetadataTree(gitDirectoryURL)
        return gitDirectoryURL
    }

    private static func validateGitMetadataTree(_ gitDirectoryURL: URL) throws {
        var entryCount = 0
        func visit(_ directoryURL: URL, relativePath: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [])
            for childURL in children {
                entryCount += 1
                try require(entryCount <= maximumGitMetadataEntries,
                            "SourcePackages Git metadata contains too many entries.")
                let path = relativePath.isEmpty ? childURL.lastPathComponent :
                    "\(relativePath)/\(childURL.lastPathComponent)"
                try ElementCallCandidatePath.validateRelative(path)
                try require(path != "refs/replace" && !path.hasPrefix("refs/replace/"),
                            "SourcePackages Git metadata contains replacement refs.")
                var information = stat()
                try require(lstat(childURL.path, &information) == 0,
                            "SourcePackages Git metadata changed during validation.")
                let type = information.st_mode & S_IFMT
                if type == S_IFDIR {
                    try visit(childURL, relativePath: path)
                } else {
                    try require(type == S_IFREG,
                                "SourcePackages Git metadata must contain only real files and directories.")
                    let components = path.split(separator: "/")
                    if components.count >= 2, components[components.count - 2] == "hooks" {
                        try require(childURL.lastPathComponent.hasSuffix(".sample"),
                                    "SourcePackages Git metadata contains an active hook.")
                    }
                }
            }
        }
        try visit(gitDirectoryURL, relativePath: "")
        let packedRefsURL = gitDirectoryURL.appending(path: "packed-refs")
        if FileManager.default.fileExists(atPath: packedRefsURL.path) {
            let packedRefs = try Data(contentsOf: packedRefsURL)
            try require(packedRefs.count <= 64 * 1024 * 1024,
                        "SourcePackages packed refs are too large.")
            guard let value = String(data: packedRefs, encoding: .utf8) else {
                throw ElementCallCandidateError.validation("SourcePackages packed refs are not UTF-8.")
            }
            try require(!value.split(whereSeparator: \.isNewline).contains(where: { $0.hasSuffix(" refs/replace") ||
                    $0.contains(" refs/replace/")
            }), "SourcePackages Git metadata contains packed replacement refs.")
        }
    }

    private static func validateLocalConfiguration(checkoutURL: URL,
                                                   gitDirectoryURL: URL,
                                                   topLevel: Bool) throws {
        let data = try gitData(["-C", checkoutURL.path, "config", "--local", "--no-includes", "--null", "--list"])
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let separator = record.firstIndex(of: 0x0A), separator < record.endIndex,
                  let key = String(data: Data(record[..<separator]), encoding: .utf8)?.lowercased(),
                  let value = String(data: Data(record[record.index(after: separator)...]), encoding: .utf8) else {
                throw ElementCallCandidateError.validation("A SourcePackages checkout local Git configuration is invalid.")
            }
            if key == "core.worktree" {
                try require(!topLevel,
                            "A top-level SourcePackages checkout cannot override core.worktree.")
                let unresolved = value.hasPrefix("/") ? value : gitDirectoryURL.appending(path: value).path
                guard let resolved = realpath(unresolved, nil), let checkout = realpath(checkoutURL.path, nil) else {
                    throw ElementCallCandidateError.validation("A SourcePackages submodule core.worktree is invalid.")
                }
                defer {
                    free(resolved)
                    free(checkout)
                }
                try require(String(cString: resolved) == String(cString: checkout),
                            "A SourcePackages submodule core.worktree escapes its checkout.")
            }
            let forbidden = key.hasPrefix("filter.") || key.hasPrefix("include.") || key.hasPrefix("includeif.") ||
                key.hasPrefix("credential.") || key.hasPrefix("url.") ||
                key == "core.attributesfile" || key == "core.excludesfile" || key == "core.hookspath" ||
                key == "core.gitproxy" || key == "core.sshcommand" || key == "extensions.worktreeconfig" ||
                (key == "core.fsmonitor" && value != "false") ||
                (key.hasPrefix("remote.") &&
                    (key.hasSuffix(".uploadpack") || key.hasSuffix(".receivepack") || key.hasSuffix(".vcs"))) ||
                (key.hasPrefix("submodule.") && key.hasSuffix(".update"))
            try require(!forbidden,
                        "A SourcePackages checkout contains executable or external local Git configuration: \(key).")
        }
    }

    private static func validateObjectStore(_ objectStoreURL: URL,
                                            sourcePackagesRootURL: URL,
                                            validatedObjectStores: inout Set<String>,
                                            depth: Int) throws {
        try require(depth <= maximumAlternateObjectStores,
                    "SourcePackages Git alternates exceed the supported depth.")
        _ = try relativePath(objectStoreURL.path, beneath: sourcePackagesRootURL)
        _ = try ElementCallCandidatePath.validateExisting(objectStoreURL, kind: .directory,
                                                          label: "SourcePackages Git object store")
        guard validatedObjectStores.insert(objectStoreURL.path).inserted else { return }
        try require(validatedObjectStores.count <= maximumAlternateObjectStores,
                    "SourcePackages Git alternates contain too many object stores.")
        guard let paths = try alternatePaths(objectStoreURL: objectStoreURL) else { return }
        for path in paths {
            let relative = try relativePath(path, beneath: sourcePackagesRootURL)
            try require(URL(filePath: relative).lastPathComponent == "objects",
                        "A SourcePackages Git alternate does not identify an object store.")
            try validateObjectStore(URL(filePath: path),
                                    sourcePackagesRootURL: sourcePackagesRootURL,
                                    validatedObjectStores: &validatedObjectStores,
                                    depth: depth + 1)
        }
    }

    private static func alternatePaths(objectStoreURL: URL) throws -> [String]? {
        let alternatesURL = objectStoreURL.appending(path: "info/alternates")
        var information = stat()
        let result = lstat(alternatesURL.path, &information)
        if result != 0 {
            try require(errno == ENOENT, "SourcePackages Git alternates are unavailable.")
            return nil
        }
        _ = try ElementCallCandidatePath.validateExisting(alternatesURL, kind: .file,
                                                          label: "SourcePackages Git alternates")
        let data = try Data(contentsOf: alternatesURL)
        try require(data.count <= 64 * 1024,
                    "SourcePackages Git alternates are too large.")
        guard let value = String(data: data, encoding: .utf8) else {
            throw ElementCallCandidateError.validation("SourcePackages Git alternates are not UTF-8.")
        }
        let paths = value.split(whereSeparator: { $0.isNewline }).map(String.init)
        try require(!paths.isEmpty, "SourcePackages Git alternates are empty.")
        try require(Set(paths).count == paths.count,
                    "SourcePackages Git alternates contain duplicate object stores.")
        return paths
    }

    private static func gitBlobID(url: URL, mode: String, byteCount: Int64) throws -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(byteCount)\0".utf8))
        if mode == "120000" {
            let bytes = try Data(FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            try require(bytes.count == Int(byteCount),
                        "A SourcePackages checkout symlink changed during byte verification.")
            hasher.update(data: bytes)
        } else {
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            try require(descriptor >= 0, "Unable to open a SourcePackages checkout file without following links.")
            defer { close(descriptor) }
            var information = stat()
            try require(fstat(descriptor, &information) == 0 && information.st_mode & S_IFMT == S_IFREG &&
                information.st_size == byteCount,
                "A SourcePackages checkout file changed during byte verification.")
            var totalBytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                try require(count >= 0, "Unable to read a SourcePackages checkout file.")
                if count == 0 { break }
                totalBytes += Int64(count)
                try require(totalBytes <= byteCount,
                            "A SourcePackages checkout file changed during byte verification.")
                hasher.update(data: Data(buffer[..<count]))
            }
            var finalInformation = stat()
            try require(totalBytes == byteCount && fstat(descriptor, &finalInformation) == 0 &&
                finalInformation.st_size == byteCount,
                "A SourcePackages checkout file changed during byte verification.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func matchesFilteredWorktreeBytes(checkoutURL: URL,
                                                     fileURL: URL,
                                                     path: String,
                                                     objectID: String,
                                                     byteCount: Int64) throws -> Bool {
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        try require(descriptor >= 0,
                    "Unable to open a SourcePackages checkout file for attribute verification.")
        defer { close(descriptor) }
        var initialInformation = stat()
        try require(fstat(descriptor, &initialInformation) == 0 &&
            initialInformation.st_mode & S_IFMT == S_IFREG && initialInformation.st_size == byteCount,
            "A SourcePackages checkout file changed during attribute verification.")

        let process = gitProcess(["-C", checkoutURL.path, "cat-file", "--filters",
                                  "--path=\(path)", objectID])
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()

        var matches = true
        var totalBytes: Int64 = 0
        while true {
            let expected = output.fileHandleForReading.readData(ofLength: 64 * 1024)
            if expected.isEmpty { break }
            totalBytes += Int64(expected.count)
            var actual = Data(count: expected.count)
            var offset = 0
            while offset < expected.count {
                let count = actual.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress!.advanced(by: offset), expected.count - offset)
                }
                if count < 0, errno == EINTR { continue }
                try require(count >= 0,
                            "Unable to read a SourcePackages checkout file during attribute verification.")
                if count == 0 { break }
                offset += count
            }
            if offset != expected.count || actual != expected {
                matches = false
            }
        }
        process.waitUntilExit()
        try require(process.terminationReason == .exit && process.terminationStatus == 0,
                    "Unable to apply tracked Git attributes while verifying SourcePackages bytes.")
        var finalInformation = stat()
        try require(fstat(descriptor, &finalInformation) == 0 &&
            finalInformation.st_mode & S_IFMT == S_IFREG && finalInformation.st_size == byteCount,
            "A SourcePackages checkout file changed during attribute verification.")
        return matches && totalBytes == byteCount
    }

    private static func rebaseAlternates(checkoutURL: URL,
                                         sourceRootURL: URL,
                                         stagedRootURL: URL,
                                         rebasedObjectStores: inout Set<String>,
                                         depth: Int) throws {
        try require(depth <= maximumSubmoduleDepth,
                    "SourcePackages submodules exceed the supported rebasing depth.")
        let gitDirectoryURL = try validatedGitDirectory(checkoutURL: checkoutURL,
                                                        sourcePackagesRootURL: stagedRootURL)
        try rebaseObjectStore(gitDirectoryURL.appending(path: "objects"),
                              sourceRootURL: sourceRootURL,
                              stagedRootURL: stagedRootURL,
                              rebasedObjectStores: &rebasedObjectStores,
                              depth: 0)
        let head = try gitString(["-C", checkoutURL.path, "rev-parse", "--verify", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for entry in try treeEntries(checkoutURL: checkoutURL, revision: head) where entry.isSubmodule {
            try rebaseAlternates(checkoutURL: checkoutURL.appending(path: entry.path),
                                 sourceRootURL: sourceRootURL,
                                 stagedRootURL: stagedRootURL,
                                 rebasedObjectStores: &rebasedObjectStores,
                                 depth: depth + 1)
        }
    }

    private static func rebaseObjectStore(_ objectStoreURL: URL,
                                          sourceRootURL: URL,
                                          stagedRootURL: URL,
                                          rebasedObjectStores: inout Set<String>,
                                          depth: Int) throws {
        try require(depth <= maximumAlternateObjectStores,
                    "SourcePackages Git alternates exceed the supported rebasing depth.")
        _ = try relativePath(objectStoreURL.path, beneath: stagedRootURL)
        _ = try ElementCallCandidatePath.validateExisting(objectStoreURL, kind: .directory,
                                                          label: "staged SourcePackages Git object store")
        guard rebasedObjectStores.insert(objectStoreURL.path).inserted else { return }
        try require(rebasedObjectStores.count <= maximumAlternateObjectStores,
                    "SourcePackages Git alternates contain too many staged object stores.")
        guard let paths = try alternatePaths(objectStoreURL: objectStoreURL) else { return }
        let rebasedPaths = try paths.map { path -> String in
            if path.hasPrefix(sourceRootURL.path + "/") {
                let relative = try relativePath(path, beneath: sourceRootURL)
                return stagedRootURL.appending(path: relative).path
            }
            _ = try relativePath(path, beneath: stagedRootURL)
            return path
        }
        let alternatesURL = objectStoreURL.appending(path: "info/alternates")
        try Data((rebasedPaths.joined(separator: "\n") + "\n").utf8).write(to: alternatesURL, options: .atomic)
        try require(chmod(alternatesURL.path, 0o600) == 0,
                    "Unable to secure staged SourcePackages Git alternates.")
        for path in rebasedPaths {
            try rebaseObjectStore(URL(filePath: path),
                                  sourceRootURL: sourceRootURL,
                                  stagedRootURL: stagedRootURL,
                                  rebasedObjectStores: &rebasedObjectStores,
                                  depth: depth + 1)
        }
    }

    private static func relativePath(_ path: String, beneath rootURL: URL) throws -> String {
        try ElementCallCandidatePath.validateRecordedAbsolute(path, label: "SourcePackages Git path")
        let prefix = rootURL.path + "/"
        try require(path.hasPrefix(prefix), "A SourcePackages Git path escapes its root.")
        let relative = String(path.dropFirst(prefix.count))
        try ElementCallCandidatePath.validateRelative(relative)
        return relative
    }

    private static func gitData(_ arguments: [String]) throws -> Data {
        let process = gitProcess(arguments)
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ElementCallCandidateError.validation(detail.map {
                "Unable to validate SourcePackages Git bytes. \($0)"
            } ?? "Unable to validate SourcePackages Git bytes.")
        }
        return data
    }

    private static func gitProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false",
                             "-c", "core.hooksPath=/dev/null", "-c", "credential.helper="] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_CONFIG_NOSYSTEM": "1", "GIT_NO_LAZY_FETCH": "1",
                               "GIT_NO_REPLACE_OBJECTS": "1", "GIT_OPTIONAL_LOCKS": "0",
                               "GIT_TERMINAL_PROMPT": "0", "HOME": "/var/empty",
                               "XDG_CONFIG_HOME": "/var/empty"]
        return process
    }

    private static func gitString(_ arguments: [String]) throws -> String {
        let data = try gitData(arguments)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ElementCallCandidateError.validation("SourcePackages Git output is not UTF-8.")
        }
        return value
    }

    private static func utf8Less(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool,
                                _ message: String) throws {
        guard try condition() else { throw ElementCallCandidateError.validation(message) }
    }
}
