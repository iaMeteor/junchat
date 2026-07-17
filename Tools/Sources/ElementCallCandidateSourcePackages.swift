/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import Darwin
import Foundation

enum ElementCallCandidateSourcePackages {
    private static let maximumCachedEntries = 1_000_000

    private struct LockedPin: Equatable {
        let identity: String
        let kind: String
        let location: String
        let state: Data
        let revision: String
    }

    private struct Dependency {
        let pin: LockedPin
        let subpath: String
    }

    private struct ValidationSnapshot {
        let workspaceStateData: Data
        let origins: [String: String]
        let dependencies: [Dependency]
    }

    static func resolve(path: String?, candidateRequested: Bool) throws -> URL? {
        if !candidateRequested, path == nil {
            return nil
        }
        try candidateSourcePackagesRequire(candidateRequested && path != nil,
                                           "A SourcePackages seed is required only for a candidate build.")
        try ElementCallCandidatePath.validateRecordedAbsolute(path!, label: "SourcePackages seed path")
        return URL(filePath: path!)
    }

    static func stage(from sourceURL: URL,
                      publicResolutionData: Data,
                      under candidateRootURL: URL) throws -> URL {
        _ = try ElementCallCandidatePath.validateExisting(sourceURL, kind: .directory,
                                                          label: "SourcePackages seed")
        _ = try ElementCallCandidatePath.validateExisting(candidateRootURL, kind: .directory,
                                                          label: "candidate staging root")
        try requirePrivateDirectory(candidateRootURL)
        try requireDisjoint(sourceURL, candidateRootURL)

        let expectedPins = try decodePublicPins(publicResolutionData)
        let sourceSnapshot = try validate(rootURL: sourceURL, expectedPins: expectedPins)
        let stagedURL = candidateRootURL.appending(path: "SourcePackages")
        try candidateSourcePackagesRequire(!FileManager.default.fileExists(atPath: stagedURL.path),
                                           "The staged SourcePackages destination already exists.")

        try copyOnWrite(sourceURL, to: stagedURL)
        try candidateSourcePackagesRequire(chmod(stagedURL.path, 0o700) == 0,
                                           "Unable to secure the staged SourcePackages root.")
        try requirePrivateDirectory(stagedURL)
        try rewriteWorkspaceState(sourceRootURL: sourceURL,
                                  stagedRootURL: stagedURL)
        try rebaseCheckoutOrigins(dependencies: sourceSnapshot.dependencies,
                                  sourceRootURL: sourceURL,
                                  stagedRootURL: stagedURL)
        for dependency in sourceSnapshot.dependencies {
            try ElementCallCandidateGitCheckout.rebaseAlternates(checkoutURL: stagedURL.appending(path: "checkouts").appending(path: dependency.subpath),
                                                                 sourceRootURL: sourceURL,
                                                                 stagedRootURL: stagedURL)
        }

        _ = try validate(rootURL: stagedURL, expectedPins: expectedPins)
        let sourceAfter = try validate(rootURL: sourceURL, expectedPins: expectedPins)
        try candidateSourcePackagesRequire(sourceAfter.workspaceStateData == sourceSnapshot.workspaceStateData &&
            sourceAfter.origins == sourceSnapshot.origins,
            "Staging changed the SourcePackages seed.")
        return stagedURL
    }

    private static func decodePublicPins(_ data: Data) throws -> [LockedPin] {
        try ElementCallCandidateJSON.validateUniqueKeys(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElementCallCandidateError.validation("The public Package.resolved must be a JSON object.")
        }
        try candidateSourcePackagesRequire(Set(root.keys) == ["originHash", "pins", "version"],
                                           "The public Package.resolved fields are invalid.")
        try candidateSourcePackagesRequire(ElementCallCandidateJSON.safeInteger(root["version"], label: "Package.resolved version") == 3,
                                           "The public Package.resolved must use schema version 3.")
        try candidateSourcePackagesRequire((root["originHash"] as? String).map {
            ElementCallCandidateRequest.isLowercaseHex($0, count: 64)
        } == true, "The public Package.resolved origin hash is invalid.")
        guard let values = root["pins"] as? [[String: Any]] else {
            throw ElementCallCandidateError.validation("The public Package.resolved pins field is invalid.")
        }
        var identities = Set<String>()
        let pins = try values.map { pin -> LockedPin in
            try candidateSourcePackagesRequire(Set(pin.keys) == ["identity", "kind", "location", "state"],
                                               "A public Package.resolved pin has invalid fields.")
            guard let identity = pin["identity"] as? String, !identity.isEmpty,
                  let kind = pin["kind"] as? String, !kind.isEmpty,
                  let location = pin["location"] as? String, !location.isEmpty,
                  let state = pin["state"] as? [String: Any] else {
                throw ElementCallCandidateError.validation("A public Package.resolved pin is invalid.")
            }
            try candidateSourcePackagesRequire(identities.insert(identity).inserted,
                                               "The public Package.resolved contains a duplicate identity.")
            let revision = try validateCheckoutState(state,
                                                     label: "public Package.resolved checkout state")
            return try LockedPin(identity: identity,
                                 kind: kind,
                                 location: location,
                                 state: canonicalJSON(state),
                                 revision: revision)
        }
        return pins.sorted { $0.identity < $1.identity }
    }

    private static func validate(rootURL: URL,
                                 expectedPins: [LockedPin]) throws -> ValidationSnapshot {
        _ = try ElementCallCandidatePath.validateExisting(rootURL, kind: .directory,
                                                          label: "SourcePackages root")
        let workspaceStateURL = rootURL.appending(path: "workspace-state.json")
        _ = try ElementCallCandidatePath.validateExisting(workspaceStateURL, kind: .file,
                                                          label: "SourcePackages workspace state")
        let workspaceStateData = try Data(contentsOf: workspaceStateURL)
        try ElementCallCandidateJSON.validateUniqueKeys(workspaceStateData)
        guard let root = try JSONSerialization.jsonObject(with: workspaceStateData) as? [String: Any] else {
            throw ElementCallCandidateError.validation("The SourcePackages workspace state must be a JSON object.")
        }
        try candidateSourcePackagesRequire(Set(root.keys) == ["object", "version"],
                                           "The SourcePackages workspace state fields are invalid.")
        try candidateSourcePackagesRequire(ElementCallCandidateJSON.safeInteger(root["version"], label: "workspace state version") == 7,
                                           "The SourcePackages workspace state must use schema version 7.")
        guard let object = root["object"] as? [String: Any] else {
            throw ElementCallCandidateError.validation("The SourcePackages workspace state object is invalid.")
        }
        try candidateSourcePackagesRequire(Set(object.keys) == ["artifacts", "dependencies", "prebuilts"],
                                           "The SourcePackages workspace object fields are invalid.")
        let dependencies = try decodeDependencies(object["dependencies"])
        let actualPins = dependencies.map(\.pin).sorted { $0.identity < $1.identity }
        try candidateSourcePackagesRequire(actualPins == expectedPins,
                                           "The SourcePackages dependencies differ from the public Package.resolved pins.")
        try validateArtifacts(object["artifacts"], rootURL: rootURL)
        try validatePrebuilts(object["prebuilts"], rootURL: rootURL)

        var origins = [String: String]()
        for dependency in dependencies {
            let checkoutURL = rootURL.appending(path: "checkouts").appending(path: dependency.subpath)
            _ = try ElementCallCandidatePath.validateExisting(checkoutURL, kind: .directory,
                                                              label: "SourcePackages checkout")
            try validateGitMetadata(checkoutURL: checkoutURL,
                                    sourcePackagesRootURL: rootURL,
                                    topLevel: true,
                                    depth: 0)
            let head = try gitString(["-C", checkoutURL.path, "rev-parse", "--verify", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try candidateSourcePackagesRequire(head == dependency.pin.revision,
                                               "A SourcePackages checkout HEAD differs from Package.resolved.")
            try ElementCallCandidateGitCheckout.validate(checkoutURL: checkoutURL,
                                                         revision: dependency.pin.revision,
                                                         sourcePackagesRootURL: rootURL)
            let origin = try gitString(["-C", checkoutURL.path, "remote", "get-url", "origin"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try localRepositoryRelativePath(origin, rootURL: rootURL)
            try candidateSourcePackagesRequire(origins.updateValue(origin, forKey: dependency.pin.identity) == nil,
                                               "The SourcePackages workspace contains a duplicate checkout identity.")
        }
        return ValidationSnapshot(workspaceStateData: workspaceStateData,
                                  origins: origins,
                                  dependencies: dependencies)
    }

    private static func decodeDependencies(_ value: Any?) throws -> [Dependency] {
        guard let values = value as? [[String: Any]] else {
            throw ElementCallCandidateError.validation("The SourcePackages dependencies field is invalid.")
        }
        var identities = Set<String>()
        return try values.map { dependency -> Dependency in
            try candidateSourcePackagesRequire(Set(dependency.keys) == ["basedOn", "packageRef", "state", "subpath"] &&
                dependency["basedOn"] is NSNull,
                "A SourcePackages dependency has invalid fields.")
            guard let packageReference = dependency["packageRef"] as? [String: Any],
                  Set(packageReference.keys) == ["identity", "kind", "location", "name"],
                  let identity = packageReference["identity"] as? String, !identity.isEmpty,
                  let kind = packageReference["kind"] as? String, !kind.isEmpty,
                  let location = packageReference["location"] as? String, !location.isEmpty,
                  let name = packageReference["name"] as? String, !name.isEmpty,
                  let state = dependency["state"] as? [String: Any],
                  Set(state.keys) == ["checkoutState", "name"],
                  state["name"] as? String == "sourceControlCheckout",
                  let checkoutState = state["checkoutState"] as? [String: Any],
                  let subpath = dependency["subpath"] as? String else {
                throw ElementCallCandidateError.validation("A SourcePackages dependency is invalid.")
            }
            let revision = try validateCheckoutState(checkoutState,
                                                     label: "SourcePackages checkout state")
            try ElementCallCandidatePath.validateRelative(subpath)
            try candidateSourcePackagesRequire(identities.insert(identity).inserted,
                                               "The SourcePackages workspace contains a duplicate identity.")
            let pin = try LockedPin(identity: identity,
                                    kind: kind,
                                    location: location,
                                    state: canonicalJSON(checkoutState),
                                    revision: revision)
            return Dependency(pin: pin, subpath: subpath)
        }
    }

    private static func validateArtifacts(_ value: Any?, rootURL: URL) throws {
        guard let artifacts = value as? [[String: Any]] else {
            throw ElementCallCandidateError.validation("The SourcePackages artifacts field is invalid.")
        }
        for artifact in artifacts {
            try candidateSourcePackagesRequire(Set(artifact.keys) == ["kind", "packageRef", "path", "source", "targetName"],
                                               "A SourcePackages artifact has invalid fields.")
            guard artifact["kind"] is [String: Any], artifact["packageRef"] is [String: Any],
                  artifact["source"] is [String: Any], artifact["targetName"] is String,
                  let path = artifact["path"] as? String else {
                throw ElementCallCandidateError.validation("A SourcePackages artifact is invalid.")
            }
            try validateCachedDirectory(path, rootURL: rootURL, label: "SourcePackages artifact")
        }
    }

    private static func validateCheckoutState(_ state: [String: Any],
                                              label: String) throws -> String {
        let keys = Set(state.keys)
        try candidateSourcePackagesRequire(keys == ["revision"] || keys == ["revision", "version"],
                                           "The \(label) fields are invalid.")
        guard let revision = state["revision"] as? String,
              ElementCallCandidateRequest.isLowercaseHex(revision, count: 40) else {
            throw ElementCallCandidateError.validation("The \(label) revision is invalid.")
        }
        if keys.contains("version") {
            try candidateSourcePackagesRequire((state["version"] as? String)?.isEmpty == false,
                                               "The \(label) version is invalid.")
        }
        return revision
    }

    private static func validatePrebuilts(_ value: Any?, rootURL: URL) throws {
        guard let prebuilts = value as? [[String: Any]] else {
            throw ElementCallCandidateError.validation("The SourcePackages prebuilts field is invalid.")
        }
        let expectedKeys: Set = ["checkoutPath", "cModules", "identity", "includePath",
                                 "libraryName", "path", "products", "version"]
        for prebuilt in prebuilts {
            try candidateSourcePackagesRequire(Set(prebuilt.keys) == expectedKeys,
                                               "A SourcePackages prebuilt has invalid fields.")
            guard let checkoutPath = prebuilt["checkoutPath"] as? String,
                  let path = prebuilt["path"] as? String,
                  prebuilt["cModules"] is [Any], prebuilt["includePath"] is [Any],
                  prebuilt["products"] is [Any], prebuilt["identity"] is String,
                  prebuilt["libraryName"] is String, prebuilt["version"] is String else {
                throw ElementCallCandidateError.validation("A SourcePackages prebuilt is invalid.")
            }
            try validateCachedDirectory(checkoutPath, rootURL: rootURL,
                                        label: "SourcePackages prebuilt checkout")
            try validateCachedDirectory(path, rootURL: rootURL, label: "SourcePackages prebuilt")
        }
    }

    private static func validateCachedDirectory(_ path: String,
                                                rootURL: URL,
                                                label: String) throws {
        _ = try relativePath(path, beneath: rootURL)
        let directoryURL = try ElementCallCandidatePath.validateExisting(URL(filePath: path), kind: .directory,
                                                                         label: label)
        var entryCount = 0
        func visit(_ currentURL: URL) throws {
            let children = try FileManager.default.contentsOfDirectory(at: currentURL,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [])
            for childURL in children {
                entryCount += 1
                try candidateSourcePackagesRequire(entryCount <= maximumCachedEntries,
                                                   "A SourcePackages cached directory contains too many entries.")
                var information = stat()
                try candidateSourcePackagesRequire(lstat(childURL.path, &information) == 0,
                                                   "A SourcePackages cached entry changed during validation.")
                switch information.st_mode & S_IFMT {
                case S_IFDIR:
                    try visit(childURL)
                case S_IFREG:
                    break
                case S_IFLNK:
                    try ElementCallCandidatePath.validateSymlink(childURL, beneath: rootURL,
                                                                 label: "SourcePackages cached symlink")
                default:
                    throw ElementCallCandidateError.validation("A SourcePackages cached directory contains an unsupported entry type.")
                }
            }
        }
        try visit(directoryURL)
    }

    private static func validateGitMetadata(checkoutURL: URL,
                                            sourcePackagesRootURL: URL,
                                            topLevel: Bool,
                                            depth: Int) throws {
        try candidateSourcePackagesRequire(depth <= 16,
                                           "SourcePackages submodules exceed the supported nesting depth.")
        let metadataURL = checkoutURL.appending(path: ".git")
        if topLevel {
            _ = try ElementCallCandidatePath.validateExisting(metadataURL, kind: .directory,
                                                              label: "SourcePackages checkout Git metadata")
        } else {
            var information = stat()
            try candidateSourcePackagesRequire(lstat(metadataURL.path, &information) == 0,
                                               "SourcePackages submodule Git metadata is unavailable.")
            let type = information.st_mode & S_IFMT
            if type == S_IFDIR {
                _ = try ElementCallCandidatePath.validateExisting(metadataURL, kind: .directory,
                                                                  label: "SourcePackages submodule Git metadata")
            } else {
                _ = try ElementCallCandidatePath.validateExisting(metadataURL, kind: .file,
                                                                  label: "SourcePackages submodule Git metadata")
                let data = try Data(contentsOf: metadataURL)
                try candidateSourcePackagesRequire(data.count <= 4096,
                                                   "SourcePackages submodule Git metadata is too large.")
                guard let value = String(data: data, encoding: .utf8),
                      value.hasPrefix("gitdir: ") else {
                    throw ElementCallCandidateError.validation("SourcePackages submodule Git metadata is invalid.")
                }
                let gitDirectory = value.dropFirst("gitdir: ".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try candidateSourcePackagesRequire(!gitDirectory.isEmpty && !gitDirectory.contains("\0"),
                                                   "SourcePackages submodule Git metadata is invalid.")
                let unresolved = gitDirectory.hasPrefix("/") ? String(gitDirectory) :
                    metadataURL.deletingLastPathComponent().appending(path: String(gitDirectory)).path
                guard let resolved = realpath(unresolved, nil) else {
                    throw ElementCallCandidateError.validation("Unable to resolve SourcePackages submodule Git metadata.")
                }
                defer { free(resolved) }
                let resolvedURL = URL(filePath: String(cString: resolved))
                _ = try relativePath(resolvedURL.path, beneath: sourcePackagesRootURL)
                _ = try ElementCallCandidatePath.validateExisting(resolvedURL, kind: .directory,
                                                                  label: "SourcePackages submodule Git directory")
            }
        }

        let modulesURL = checkoutURL.appending(path: ".gitmodules")
        guard FileManager.default.fileExists(atPath: modulesURL.path) else { return }
        _ = try ElementCallCandidatePath.validateExisting(modulesURL, kind: .file,
                                                          label: "SourcePackages .gitmodules")
        let output = try gitData(["config", "--file", modulesURL.path, "--null", "--get-regexp", "\\.path$"])
        let records = output.split(separator: 0, omittingEmptySubsequences: true)
        try candidateSourcePackagesRequire(!records.isEmpty,
                                           "SourcePackages .gitmodules contains no submodule paths.")
        for record in records {
            guard let separator = record.firstIndex(of: 0x0A), separator < record.endIndex,
                  let path = String(data: Data(record[record.index(after: separator)...]), encoding: .utf8) else {
                throw ElementCallCandidateError.validation("SourcePackages .gitmodules output is invalid.")
            }
            try ElementCallCandidatePath.validateRelative(path)
            let submoduleURL = checkoutURL.appending(path: path)
            _ = try ElementCallCandidatePath.validateExisting(submoduleURL, kind: .directory,
                                                              label: "SourcePackages submodule checkout")
            try validateGitMetadata(checkoutURL: submoduleURL,
                                    sourcePackagesRootURL: sourcePackagesRootURL,
                                    topLevel: false,
                                    depth: depth + 1)
        }
    }

    private static func rewriteWorkspaceState(sourceRootURL: URL,
                                              stagedRootURL: URL) throws {
        let workspaceStateURL = stagedRootURL.appending(path: "workspace-state.json")
        let data = try Data(contentsOf: workspaceStateURL)
        try ElementCallCandidateJSON.validateUniqueKeys(data)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var object = root["object"] as? [String: Any],
              var artifacts = object["artifacts"] as? [[String: Any]],
              var prebuilts = object["prebuilts"] as? [[String: Any]] else {
            throw ElementCallCandidateError.validation("Unable to rewrite the staged SourcePackages workspace state.")
        }
        for index in artifacts.indices {
            guard let path = artifacts[index]["path"] as? String else {
                throw ElementCallCandidateError.validation("A staged SourcePackages artifact path is invalid.")
            }
            artifacts[index]["path"] = try rebasedPath(path, sourceRootURL: sourceRootURL,
                                                       stagedRootURL: stagedRootURL)
        }
        for index in prebuilts.indices {
            for key in ["checkoutPath", "path"] {
                guard let path = prebuilts[index][key] as? String else {
                    throw ElementCallCandidateError.validation("A staged SourcePackages prebuilt path is invalid.")
                }
                prebuilts[index][key] = try rebasedPath(path, sourceRootURL: sourceRootURL,
                                                        stagedRootURL: stagedRootURL)
            }
        }
        object["artifacts"] = artifacts
        object["prebuilts"] = prebuilts
        root["object"] = object
        try writePrivateJSON(root, replacing: workspaceStateURL)
    }

    private static func rebaseCheckoutOrigins(dependencies: [Dependency],
                                              sourceRootURL: URL,
                                              stagedRootURL: URL) throws {
        for dependency in dependencies {
            let stagedCheckoutURL = stagedRootURL.appending(path: "checkouts").appending(path: dependency.subpath)
            let origin = try gitString(["-C", stagedCheckoutURL.path, "remote", "get-url", "origin"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rebasedOrigin = try rebasedPath(origin,
                                                sourceRootURL: sourceRootURL,
                                                stagedRootURL: stagedRootURL)
            _ = try gitData(["-C", stagedCheckoutURL.path, "remote", "set-url", "origin", rebasedOrigin])
        }
    }

    private static func rebasedPath(_ path: String,
                                    sourceRootURL: URL,
                                    stagedRootURL: URL) throws -> String {
        let relative = try relativePath(path, beneath: sourceRootURL)
        return stagedRootURL.appending(path: relative).path
    }

    private static func localRepositoryRelativePath(_ path: String, rootURL: URL) throws -> String {
        let relative = try relativePath(path, beneath: rootURL)
        try candidateSourcePackagesRequire(relative.hasPrefix("repositories/"),
                                           "A SourcePackages checkout origin is outside its repositories directory.")
        _ = try ElementCallCandidatePath.validateExisting(URL(filePath: path), kind: .directory,
                                                          label: "SourcePackages repository")
        return relative
    }

    private static func relativePath(_ path: String, beneath rootURL: URL) throws -> String {
        try ElementCallCandidatePath.validateRecordedAbsolute(path, label: "SourcePackages cached path")
        let prefix = rootURL.path + "/"
        try candidateSourcePackagesRequire(path.hasPrefix(prefix),
                                           "A SourcePackages cached path escapes its root.")
        let relative = String(path.dropFirst(prefix.count))
        try ElementCallCandidatePath.validateRelative(relative)
        return relative
    }

    private static func requireDisjoint(_ sourceURL: URL, _ candidateRootURL: URL) throws {
        let source = sourceURL.path + "/"
        let candidate = candidateRootURL.path + "/"
        try candidateSourcePackagesRequire(!source.hasPrefix(candidate) && !candidate.hasPrefix(source),
                                           "The SourcePackages seed and candidate staging root must be disjoint.")
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var information = stat()
        try candidateSourcePackagesRequire(lstat(url.path, &information) == 0 &&
            information.st_mode & S_IFMT == S_IFDIR && information.st_mode & 0o777 == 0o700,
            "Candidate SourcePackages directories must use mode 0700.")
    }

    private static func copyOnWrite(_ sourceURL: URL, to destinationURL: URL) throws {
        try run(executable: "/bin/cp", arguments: ["-cR", sourceURL.path, destinationURL.path],
                failure: "Unable to clone the offline SourcePackages seed.")
    }

    private static func gitData(_ arguments: [String]) throws -> Data {
        try capture(executable: "/usr/bin/git",
                    arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false",
                                "-c", "core.hooksPath=/dev/null", "-c", "credential.helper="] + arguments,
                    failure: "Unable to validate the offline SourcePackages Git state.")
    }

    private static func gitString(_ arguments: [String]) throws -> String {
        let data = try gitData(arguments)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ElementCallCandidateError.validation("SourcePackages Git output is not UTF-8.")
        }
        return value
    }

    private static func run(executable: String,
                            arguments: [String],
                            failure: String) throws {
        _ = try capture(executable: executable, arguments: arguments, failure: failure)
    }

    private static func capture(executable: String,
                                arguments: [String],
                                failure: String) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_CONFIG_NOSYSTEM": "1", "GIT_NO_LAZY_FETCH": "1",
                               "GIT_NO_REPLACE_OBJECTS": "1",
                               "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
                               "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ElementCallCandidateError.validation(detail.map { "\(failure) \($0)" } ?? failure)
        }
        return outputData
    }

    private static func writePrivateJSON(_ value: Any, replacing destinationURL: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".workspace-state.junchat-\(UUID().uuidString)")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try candidateSourcePackagesRequire(descriptor >= 0,
                                           "Unable to create a private staged workspace state.")
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove {
                unlink(temporaryURL.path)
            }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                try candidateSourcePackagesRequire(count > 0,
                                                   "Unable to write the staged workspace state.")
                offset += count
            }
        }
        try candidateSourcePackagesRequire(fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0,
                                           "Unable to secure the staged workspace state.")
        try candidateSourcePackagesRequire(rename(temporaryURL.path, destinationURL.path) == 0,
                                           "Unable to replace the staged workspace state.")
        shouldRemove = false
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

private func candidateSourcePackagesRequire(_ condition: @autoclosure () throws -> Bool,
                                            _ message: String) throws {
    guard try condition() else { throw ElementCallCandidateError.validation(message) }
}
