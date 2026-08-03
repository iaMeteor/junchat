/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum ElementCallCandidateError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message): message
        }
    }
}

private func candidateRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ElementCallCandidateError.validation(message) }
}

struct ElementCallCandidateRequest {
    let manifestURL: URL
    let manifestSHA256: String
    let sourceCommit: String

    static func resolve(manifestPath: String?, manifestSHA256: String?, sourceCommit: String?) throws -> Self? {
        let values = [manifestPath, manifestSHA256, sourceCommit]
        if values.allSatisfy({ $0 == nil }) {
            return nil
        }
        try candidateRequire(values.allSatisfy { $0 != nil },
                             "Manifest path, manifest SHA-256, and source commit are all required for a candidate build.")
        try candidateRequire(Self.isLowercaseHex(manifestSHA256!, count: 64),
                             "The expected candidate manifest SHA-256 must be 64 lowercase hexadecimal characters.")
        try candidateRequire(Self.isLowercaseHex(sourceCommit!, count: 40),
                             "The expected candidate source commit must be 40 lowercase hexadecimal characters.")
        try ElementCallCandidatePath.validateRecordedAbsolute(manifestPath!, label: "candidate manifest path")
        return Self(manifestURL: URL(filePath: manifestPath!),
                    manifestSHA256: manifestSHA256!,
                    sourceCommit: sourceCommit!)
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum ElementCallCandidateJSON {
    private static let maximumNestingDepth = 128

    static func validateUniqueKeys(_ data: Data) throws {
        var parser = DuplicateKeyParser(bytes: [UInt8](data))
        try parser.parse()
    }

    static func safeInteger(_ value: Any?, label: String) throws -> Int64 {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw ElementCallCandidateError.validation("The \(label) field must be a safe integer.")
        }
        let number = value.doubleValue
        guard number.isFinite, number.rounded() == number,
              abs(number) <= 9_007_199_254_740_991 else {
            throw ElementCallCandidateError.validation("The \(label) field must be a safe integer.")
        }
        return value.int64Value
    }

    private struct DuplicateKeyParser {
        var bytes: [UInt8]
        var index = 0

        mutating func parse() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            try candidateRequire(index == bytes.count, "The candidate manifest contains trailing JSON data.")
        }

        private mutating func parseValue(depth: Int) throws {
            try candidateRequire(depth <= ElementCallCandidateJSON.maximumNestingDepth,
                                 "The candidate manifest exceeds the maximum JSON nesting depth.")
            try candidateRequire(index < bytes.count, "The candidate manifest JSON ended unexpectedly.")
            switch bytes[index] {
            case 0x7B: try parseObject(depth: depth)
            case 0x5B: try parseArray(depth: depth)
            case 0x22: _ = try parseString()
            case 0x74: try consume("true")
            case 0x66: try consume("false")
            case 0x6E: try consume("null")
            default: try parseNumber()
            }
        }

        private mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x7D) {
                return
            }
            var keys = Set<String>()
            while true {
                try candidateRequire(index < bytes.count && bytes[index] == 0x22,
                                     "The candidate manifest JSON object key must be a string.")
                let key = try parseString()
                try candidateRequire(keys.insert(key).inserted,
                                     "The candidate manifest contains a duplicate JSON key: \(key).")
                skipWhitespace()
                try expect(0x3A)
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x7D) {
                    return
                }
                try expect(0x2C)
                skipWhitespace()
            }
        }

        private mutating func parseArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x5D) {
                return
            }
            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x5D) {
                    return
                }
                try expect(0x2C)
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    var wrapped = Data("[".utf8)
                    wrapped.append(contentsOf: bytes[start..<index])
                    wrapped.append(Data("]".utf8))
                    guard let values = try? JSONSerialization.jsonObject(with: wrapped) as? [String],
                          values.count == 1 else {
                        throw ElementCallCandidateError.validation("The candidate manifest contains an invalid JSON string.")
                    }
                    return values[0]
                }
                if byte == 0x5C {
                    index += 1
                    try candidateRequire(index < bytes.count, "The candidate manifest contains an incomplete JSON escape.")
                    if bytes[index] == 0x75 {
                        try candidateRequire(index + 4 < bytes.count && bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHex),
                                             "The candidate manifest contains an invalid Unicode escape.")
                        index += 5
                    } else {
                        try candidateRequire([0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(bytes[index]),
                                             "The candidate manifest contains an invalid JSON escape.")
                        index += 1
                    }
                } else {
                    try candidateRequire(byte >= 0x20, "The candidate manifest contains an unescaped control character.")
                    index += 1
                }
            }
            throw ElementCallCandidateError.validation("The candidate manifest contains an unterminated JSON string.")
        }

        private mutating func parseNumber() throws {
            let start = index
            while index < bytes.count, [0x2D, 0x2B, 0x2E, 0x45, 0x65].contains(bytes[index]) || (48...57).contains(bytes[index]) {
                index += 1
            }
            try candidateRequire(index > start, "The candidate manifest contains an invalid JSON value.")
        }

        private mutating func consume(_ value: String) throws {
            let expected = Array(value.utf8)
            try candidateRequire(index + expected.count <= bytes.count && Array(bytes[index..<index + expected.count]) == expected,
                                 "The candidate manifest contains an invalid JSON literal.")
            index += expected.count
        }

        private mutating func expect(_ byte: UInt8) throws {
            try candidateRequire(consumeIf(byte), "The candidate manifest JSON structure is invalid.")
        }

        private mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        private static func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

enum ElementCallCandidatePath {
    enum Kind { case file, directory }

    static func systemTemporaryDirectory() throws -> URL {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw ElementCallCandidateError.validation("Unable to resolve the canonical system temporary directory.")
        }
        defer { free(resolved) }
        let url = URL(filePath: String(cString: resolved))
        return try validateExisting(url, kind: .directory, label: "system temporary directory")
    }

    static func validateRelative(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        try candidateRequire(!path.isEmpty && !path.hasPrefix("/") && !path.contains("\\"),
                             "Candidate paths must be relative POSIX paths.")
        try candidateRequire(components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },
                             "Candidate paths must not contain traversal or noncanonical components.")
    }

    static func validateRecordedAbsolute(_ path: String, label: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        try candidateRequire(path.hasPrefix("/") && path != "/" && !path.hasSuffix("/") && !path.contains("\\") &&
            components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },
            "\(label) must be a canonical absolute path.")
    }

    static func validateSymlink(_ url: URL, beneath rootURL: URL, label: String) throws {
        let rootPrefix = rootURL.path + "/"
        try candidateRequire(url.path.hasPrefix(rootPrefix), "\(label) is outside its permitted root.")
        let relativeLinkPath = String(url.path.dropFirst(rootPrefix.count))
        try validateRelative(relativeLinkPath)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        try candidateRequire(!destination.isEmpty && !destination.hasPrefix("/") && !destination.contains("\\") &&
            !destination.contains("\0"), "\(label) has an unsupported destination.")

        var components = relativeLinkPath.split(separator: "/").dropLast().map(String.init)
        for component in destination.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            } else if component == ".." {
                try candidateRequire(!components.isEmpty, "\(label) escapes its permitted root.")
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        let normalizedDestination = components.joined(separator: "/")
        try validateRelative(normalizedDestination)

        errno = 0
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            let resolvedPath = String(cString: resolved)
            try candidateRequire(resolvedPath == rootURL.path || resolvedPath.hasPrefix(rootPrefix),
                                 "\(label) escapes its permitted root.")
        } else {
            try candidateRequire(errno == ENOENT, "\(label) cannot be resolved safely.")
        }
    }

    @discardableResult
    static func validateExisting(_ url: URL, kind: Kind, label: String) throws -> URL {
        let path = url.path
        try validateRecordedAbsolute(path, label: label)
        var current = URL(filePath: "/")
        for component in url.pathComponents.dropFirst() {
            current.append(path: component)
            var information = stat()
            try candidateRequire(lstat(current.path, &information) == 0, "\(label) is unavailable: \(path).")
            try candidateRequire(information.st_mode & S_IFMT != S_IFLNK,
                                 "\(label) cannot contain a symlink component: \(current.path).")
        }
        var information = stat()
        try candidateRequire(lstat(path, &information) == 0, "\(label) is unavailable: \(path).")
        let type = information.st_mode & S_IFMT
        switch kind {
        case .file: try candidateRequire(type == S_IFREG, "\(label) must be a regular file.")
        case .directory: try candidateRequire(type == S_IFDIR, "\(label) must be a real directory.")
        }
        return url
    }
}

struct ElementCallCandidateFileSnapshot {
    let path: String
    let data: Data
}

struct ElementCallCandidatePackageSnapshot {
    let sourceCommit: String
    let version: String
    let files: [ElementCallCandidateFileSnapshot]
}

enum ElementCallCandidateManifest {
    struct FileDescription: Equatable {
        let path: String
        let sha256: String
        let size: Int64
    }

    struct TreeDescription {
        let path: String
        let treeSHA256: String
        let files: [FileDescription]
    }

    private struct ExecutionContext {
        let builderRoot: String
        let exportedSource: String
        let miseDataDirectory: String
        let outputRoot: String
        let sourceArchive: String
        let sourceRoot: String
        let temporaryRoot: String
    }

    private struct CommandSpec {
        let name: String
        let subject: String
        let arguments: [String]
        let cwd: String
        let observation: Any
        let delegated: [String]
        let sandboxed: Bool
    }

    private static let maximumManifestBytes: Int64 = 64 * 1024 * 1024
    private static let maximumArtifactBytes: Int64 = 1024 * 1024 * 1024
    private static let sandboxProfile = "(version 1) (allow default) (deny network*)"
    private static let sandboxBoundary = "darwin-sandbox-deny-network"
    private static let gradleBoundary = "offline-flags-without-os-network-sandbox"
    private static let buildEvidence = "build-time-integrity-and-same-user-forgeable-invocation-metadata-only-not-independently-revalidated"
    private static let commandStart = String(repeating: "0", count: 64)
    private static let expectedCommandNames = [
        "validate-builder-commit", "validate-builder-status", "validate-builder-tree",
        "validate-source-commit", "validate-source-status", "validate-source-tree", "archive-source",
        "revalidate-source-commit", "revalidate-source-status", "revalidate-source-tree", "extract-source",
        "resolve-pnpm-with-mise", "resolve-java-with-mise", "resolve-swift-with-xcrun", "resolve-xcodebuild-with-xcrun",
        "prove-network-sandbox", "observe-gradle-version", "observe-java-version", "observe-pnpm-version",
        "observe-swift-version", "observe-os-build-version", "observe-os-product-version",
        "observe-xcode-developer-directory", "observe-xcode-version", "install-web-dependencies",
        "build-embedded-web", "assemble-android-aar", "build-ios-package"
    ]
    private static let expectedEnvironmentNames = [
        "ANDROID_HOME", "CI", "COREPACK_HOME", "EC_VERSION", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
        "GRADLE_USER_HOME", "HOME", "LANG", "LC_ALL", "MISE_CACHE_DIR", "MISE_CONFIG_DIR", "MISE_DATA_DIR",
        "MISE_GLOBAL_CONFIG_FILE", "MISE_OFFLINE", "MISE_SYSTEM_CONFIG_FILE", "NO_COLOR", "NPM_CONFIG_CACHE",
        "NPM_CONFIG_USERCONFIG", "PATH", "PNPM_HOME", "TMPDIR", "VITE_APP_VERSION", "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "npm_config_store_dir"
    ]
    private static let expectedBinaryKeys: Set = [
        "bootstrapHelper", "buildWrapper", "candidateModule", "git", "gradleDistribution", "gradleWrapperJar",
        "gradleWrapperScript", "java", "mise", "node", "pnpm", "sandboxExec", "swift", "swVers", "tar",
        "verifyWrapper", "xcodebuild", "xcodeSelect", "xcrun"
    ]
    private static let buildChecks = [
        "clean-exact-source-record", "exact-process-command-chain-record",
        "sandbox-boundary-record-with-explicit-gradle-limitation", "cached-gradle-wrapper-distribution-sha256-record",
        "explicit-canonical-android-sdk-record", "post-stage-source-input-freeze-record", "tool-binary-sha256-record"
    ]
    private static let revalidatedChecks = [
        "strict-manifest-schema", "android-aar-structured-integrity", "cross-platform-embedded-byte-identity",
        "retained-artifact-sha256", "retained-tree-sha256"
    ]
    private static let limitations = [
        "android-dependencies-are-not-locked-by-gradle-lockfiles",
        "build-time-source-sdk-freeze-and-tool-records-are-not-independently-revalidated",
        "caller-supplied-manifest-digest-does-not-authenticate-provenance",
        "trusted-same-user-callers-can-forge-fd8-fd9-invocation-provenance-and-are-in-the-trust-base",
        "tool-binary-digests-do-not-authenticate-dynamic-libraries", "recorded-os-and-xcode-versions-are-not-provisioned",
        "local-dependency-caches-other-than-the-gradle-wrapper-are-prerequisites-not-independently-revalidated",
        "gradle-offline-mode-is-not-os-level-network-enforcement",
        "same-user-writable-inputs-caches-and-staged-files-remain-trusted-during-use"
    ]

    static func verify(_ request: ElementCallCandidateRequest) throws -> ElementCallCandidatePackageSnapshot {
        try candidateRequire(request.manifestURL.lastPathComponent == "manifest.json",
                             "The Element Call candidate manifest must be named manifest.json.")
        let manifestURL = try ElementCallCandidatePath.validateExisting(request.manifestURL,
                                                                        kind: .file,
                                                                        label: "Element Call candidate manifest")
        let candidateRoot = try ElementCallCandidatePath.validateExisting(manifestURL.deletingLastPathComponent(),
                                                                          kind: .directory,
                                                                          label: "Element Call candidate root")
        try candidateRequire(candidateRoot.lastPathComponent == request.sourceCommit,
                             "The Element Call candidate directory must match the trusted source commit.")
        let rootEntries = try FileManager.default.contentsOfDirectory(atPath: candidateRoot.path).sorted()
        try candidateRequire(rootEntries == ["android", "ios", "manifest.json", "web"],
                             "The Element Call candidate root contains unsupported or missing entries.")
        for entry in ["android", "ios", "web"] {
            _ = try ElementCallCandidatePath.validateExisting(candidateRoot.appending(path: entry),
                                                              kind: .directory,
                                                              label: "Element Call candidate \(entry) output")
        }

        let manifestData = try readFile(manifestURL, maximumBytes: maximumManifestBytes, label: "candidate manifest")
        try candidateRequire(sha256(manifestData) == request.manifestSHA256,
                             "The Element Call candidate manifest SHA-256 does not match.")
        try ElementCallCandidateJSON.validateUniqueKeys(manifestData)
        let root = try JSONObject.decode(manifestData, label: "candidate manifest")
        try root.requireKeys(["buildInputs", "builder", "checks", "cleanupOwner", "evidence", "outputs", "platform",
                              "published", "reproducibility", "schema", "source", "status", "tools", "version"])
        try candidateRequire(root.string("schema") == "junchat.element-call-candidate/v4",
                             "Unsupported Element Call candidate manifest schema.")
        try candidateRequire(root.string("status") == "built-local-only" && !(root.bool("published")),
                             "The Element Call candidate is not local-only and unpublished.")
        try validateEvidence(root.object("evidence"))

        let builder = try root.object("builder")
        _ = try validateGitIdentity(builder, label: "builder")
        let source = try root.object("source")
        let sourceCommit = try validateGitIdentity(source, label: "source")
        try candidateRequire(sourceCommit == request.sourceCommit,
                             "The Element Call candidate source commit does not match the trusted expectation.")
        let version = try root.string("version")
        try validateVersion(version, sourceCommit: sourceCommit)

        let tools = try root.object("tools")
        let platform = try root.object("platform")
        try validateTools(tools)
        try validatePlatform(platform)
        try validateBuildInputs(root.object("buildInputs"),
                                builder: builder,
                                candidateRoot: candidateRoot,
                                platform: platform,
                                source: source,
                                tools: tools,
                                version: version)
        try validatePolicy(root.object("checks"),
                           expected: ["buildTimeIntegrityOnly": buildChecks, "independentlyRevalidated": revalidatedChecks],
                           label: "candidate checks")
        let reproducibility = try root.object("reproducibility")
        try reproducibility.requireKeys(["claim", "limitations"])
        try candidateRequire(reproducibility.string("claim") == "retained-output-integrity-not-build-provenance-authentication" &&
            reproducibility.stringArray("limitations") == limitations,
            "The Element Call candidate reproducibility policy is incomplete.")
        try candidateRequire(!(root.string("cleanupOwner")).isEmpty, "The Element Call candidate cleanup owner is required.")

        let outputs = try root.object("outputs")
        try outputs.requireKeys(["androidAar", "iosPackage", "webDist"])
        let android = try outputs.object("androidAar")
        try android.requireKeys(["embeddedWeb", "path", "sha256", "size"])
        let aar = try fileDescriptionFields(android,
                                            requiredPath: "android/element-call-embedded-\(version).aar",
                                            label: "Android AAR")
        let androidWeb = try treeDescription(android.object("embeddedWeb"), requiredPath: "assets/element-call", label: "Android embedded web")
        let ios = try outputs.object("iosPackage")
        try ios.requireKeys(["embeddedWeb", "files", "path", "treeSha256"])
        let iosPackage = try treeFields(ios, requiredPath: "ios/EmbeddedElementCall", label: "iOS package")
        let iosWeb = try treeDescription(ios.object("embeddedWeb"), requiredPath: "Sources/dist", label: "iOS embedded web")
        let web = try treeDescription(outputs.object("webDist"), requiredPath: "web/element-call", label: "web dist")
        try candidateRequire(androidWeb.files == web.files && androidWeb.treeSHA256 == web.treeSHA256 &&
            iosWeb.files == web.files && iosWeb.treeSHA256 == web.treeSHA256,
            "The platform embedded web descriptions do not match.")

        let aarData = try readFile(candidateRoot.appending(path: aar.path), maximumBytes: maximumArtifactBytes, label: "candidate AAR")
        try candidateRequire(Int64(aarData.count) == aar.size && sha256(aarData) == aar.sha256,
                             "The retained Android AAR does not match its manifest.")
        try ElementCallCandidateAAR.verify(aarData,
                                           expectedEmbeddedFiles: androidWeb.files.map {
                                               ElementCallCandidateAARExpectedFile(path: $0.path,
                                                                                   sha256: $0.sha256,
                                                                                   size: $0.size)
                                           })
        _ = try verifyTree(candidateRoot.appending(path: web.path), expected: web, label: "web dist")
        let packageFiles = try verifyTree(candidateRoot.appending(path: iosPackage.path), expected: iosPackage, label: "iOS package")
        let embeddedDescriptions = packageFiles.compactMap { file -> FileDescription? in
            let prefix = "Sources/dist/"
            guard file.path.hasPrefix(prefix) else { return nil }
            return FileDescription(path: String(file.path.dropFirst(prefix.count)), sha256: sha256(file.data), size: Int64(file.data.count))
        }
        try candidateRequire(embeddedDescriptions == iosWeb.files && treeSHA256(embeddedDescriptions) == iosWeb.treeSHA256,
                             "The retained iOS embedded web tree does not match its manifest.")
        return ElementCallCandidatePackageSnapshot(sourceCommit: sourceCommit, version: version, files: packageFiles)
    }

    private static func validateEvidence(_ evidence: JSONObject) throws {
        try evidence.requireKeys(["buildRecords", "manifestDigest", "retainedOutputs"])
        let expected = [
            "buildRecords": buildEvidence,
            "manifestDigest": "caller-supplied-byte-integrity-only-not-provenance-authentication",
            "retainedOutputs": "independently-revalidated-against-retained-manifest"
        ]
        for (key, value) in expected {
            try candidateRequire(evidence.string(key) == value, "Candidate evidence policy drifted.")
        }
    }

    private static func validateBuildInputs(_ inputs: JSONObject,
                                            builder: JSONObject,
                                            candidateRoot: URL,
                                            platform: JSONObject,
                                            source: JSONObject,
                                            tools: JSONObject,
                                            version: String) throws {
        try inputs.requireKeys(["androidSdk", "commands", "dependencyResolution", "environment", "evidence", "executionContext",
                                "freezes", "sourceFiles", "sourceTree"])
        try candidateRequire(inputs.string("evidence") == buildEvidence, "Candidate build evidence policy drifted.")
        let context = try validateExecutionContext(inputs.object("executionContext"), candidateRoot: candidateRoot)
        let androidSDK = try inputs.object("androidSdk")
        try validateAndroidSDK(androidSDK)
        let environmentSHA = try validateEnvironment(inputs.object("environment"), context: context, androidSDK: androidSDK, version: version)
        let dependencyResolution = try inputs.object("dependencyResolution")
        let expectedResolution = [
            "android": "gradle-offline-with-prevalidated-wrapper-distribution",
            "cache": "dedicated-candidate-cache-with-checksum-validated-wrapper-distribution",
            "ios": "swift-no-external-dependencies-disable-automatic-resolution",
            "network": "darwin-sandbox-deny-network-except-gradle",
            "web": "pnpm-frozen-lockfile-offline"
        ]
        try dependencyResolution.requireKeys(Set(expectedResolution.keys))
        for (key, value) in expectedResolution {
            try candidateRequire(dependencyResolution.string(key) == value, "Dependency resolution policy drifted.")
        }
        try validateFreezes(inputs.array("freezes"))
        let sourceFiles = try inputs.object("sourceFiles")
        let expectedSources = [
            "androidBuildScript": "embedded/android/lib/build.gradle.kts",
            "androidGradleVersionCatalog": "embedded/android/gradle/libs.versions.toml",
            "androidGradleWrapper": "embedded/android/gradle/wrapper/gradle-wrapper.properties",
            "iosPackage": "embedded/ios/Package.swift", "webLockfile": "pnpm-lock.yaml", "webPackage": "package.json"
        ]
        try sourceFiles.requireKeys(Set(expectedSources.keys))
        for (key, path) in expectedSources {
            let sourceFile = try sourceFiles.object(key)
            try sourceFile.requireKeys(["path", "sha256", "size"])
            _ = try fileDescription(sourceFile, requiredPath: path, label: key)
        }
        let sourceTree = try inputs.object("sourceTree")
        try sourceTree.requireKeys(["files", "treeSha256"])
        _ = try treeFields(sourceTree, requiredPath: nil, label: "source tree")
        try validateCommands(inputs.object("commands"), environmentSHA: environmentSHA, context: context,
                             builder: builder, platform: platform, source: source, tools: tools)
    }

    private static func validateExecutionContext(_ value: JSONObject, candidateRoot: URL) throws -> ExecutionContext {
        let keys: Set = ["builderRoot", "exportedSource", "miseDataDirectory", "outputRoot", "sourceArchive", "sourceRoot", "temporaryRoot"]
        try value.requireKeys(keys)
        let context = try ExecutionContext(builderRoot: value.string("builderRoot"), exportedSource: value.string("exportedSource"),
                                           miseDataDirectory: value.string("miseDataDirectory"), outputRoot: value.string("outputRoot"),
                                           sourceArchive: value.string("sourceArchive"), sourceRoot: value.string("sourceRoot"),
                                           temporaryRoot: value.string("temporaryRoot"))
        for key in keys {
            try ElementCallCandidatePath.validateRecordedAbsolute(value.string(key), label: "execution context \(key)")
        }
        try candidateRequire(context.outputRoot == candidateRoot.deletingLastPathComponent().path &&
            context.exportedSource == URL(filePath: context.temporaryRoot).appending(path: "source").path &&
            context.sourceArchive == URL(filePath: context.temporaryRoot).appending(path: "source.tar").path,
            "Candidate execution context paths are inconsistent.")
        return context
    }

    private static func validateEnvironment(_ environment: JSONObject,
                                            context: ExecutionContext,
                                            androidSDK: JSONObject,
                                            version: String) throws -> String {
        try environment.requireKeys(["executed", "policy"])
        let policy = try environment.object("policy")
        try policy.requireKeys(["allowedVariables", "androidSdk", "bootstrap", "configuration", "inheritedVariables", "network", "path"])
        try candidateRequire(policy.stringArray("allowedVariables") == expectedEnvironmentNames &&
            policy.stringArray("inheritedVariables").isEmpty && policy.string("path") == "/usr/bin:/bin:/usr/sbin:/sbin" &&
            policy.string("androidSdk") == "one-explicit-canonical-root-via-android-home" &&
            policy.string("bootstrap") == "process-local-fd-exact-metadata-canonical-tools-same-user-trusted" &&
            policy.string("configuration") == "isolated-home-tool-config-and-caches" &&
            policy.string("network") == "darwin-sandbox-deny-network-except-gradle",
            "Candidate environment policy drifted.")
        let executed = try environment.object("executed")
        try executed.requireKeys(["sha256", "variables"])
        let variables = try executed.array("variables")
        let pairs: [(String, String)] = try variables.enumerated().map { index, value in
            let object = try JSONObject(value, label: "environment variable \(index)")
            try object.requireKeys(["name", "value"])
            return try (object.string("name"), object.string("value"))
        }
        try candidateRequire(pairs.map(\.0) == expectedEnvironmentNames.sorted(), "Candidate environment variables are not uniquely sorted.")
        let environmentSHA = try executed.string("sha256")
        try candidateRequire(environmentSHA == sha256(canonicalJSON(variables)), "Candidate environment SHA-256 drifted.")
        let isolation = URL(filePath: context.temporaryRoot).appending(path: "environment")
        let cache = URL(filePath: context.outputRoot).appending(path: ".candidate-cache")
        let expected = try [
            "ANDROID_HOME": androidSDK.string("root"), "CI": "1", "COREPACK_HOME": cache.appending(path: "corepack").path,
            "EC_VERSION": version, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GRADLE_USER_HOME": cache.appending(path: "gradle").path, "HOME": isolation.appending(path: "home").path,
            "LANG": "C", "LC_ALL": "C", "MISE_CACHE_DIR": cache.appending(path: "mise").path,
            "MISE_CONFIG_DIR": isolation.appending(path: "config/mise").path, "MISE_DATA_DIR": context.miseDataDirectory,
            "MISE_GLOBAL_CONFIG_FILE": isolation.appending(path: "config/mise/config.toml").path, "MISE_OFFLINE": "1",
            "MISE_SYSTEM_CONFIG_FILE": "/dev/null", "NO_COLOR": "1", "NPM_CONFIG_CACHE": cache.appending(path: "npm").path,
            "NPM_CONFIG_USERCONFIG": isolation.appending(path: "config/npm/npmrc").path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PNPM_HOME": isolation.appending(path: "data/pnpm").path, "TMPDIR": isolation.appending(path: "tmp").path,
            "VITE_APP_VERSION": "embedded-v\(version)", "XDG_CACHE_HOME": cache.appending(path: "xdg").path,
            "XDG_CONFIG_HOME": isolation.appending(path: "config").path, "XDG_DATA_HOME": isolation.appending(path: "data").path,
            "npm_config_store_dir": cache.appending(path: "pnpm/store").path
        ]
        try candidateRequire(Dictionary(uniqueKeysWithValues: pairs) == expected, "Candidate isolated environment values drifted.")
        return environmentSHA
    }

    static func validateAndroidSDK(_ sdk: JSONObject) throws {
        try sdk.requireKeys(["buildTools", "platform", "root"])
        try ElementCallCandidatePath.validateRecordedAbsolute(sdk.string("root"), label: "Android SDK root")
        let platform = try sdk.object("platform")
        try platform.requireKeys(["apiLevel", "packageId", "revision", "sourceProperties"])
        let api = try platform.integer("apiLevel")
        try candidateRequire(api > 0 && (platform.string("packageId")) == "platforms;android-\(api)", "Android SDK platform identity drifted.")
        try candidateRequire(platform.string("revision").range(of: #"^[0-9]+(?:\.[0-9]+)*$"#,
                                                               options: .regularExpression) != nil,
                             "Android SDK platform revision drifted.")
        let platformProperties = try platform.object("sourceProperties")
        try platformProperties.requireKeys(["path", "sha256", "size"])
        _ = try fileDescription(platformProperties, requiredPath: "platforms/android-\(api)/source.properties", label: "platform source properties")
        let buildTools = try sdk.object("buildTools")
        try buildTools.requireKeys(["packageId", "revision", "sourceProperties"])
        let revision = "\(api).0.0"
        try candidateRequire(buildTools.string("packageId") == "build-tools;\(revision)" && buildTools.string("revision") == revision,
                             "Android SDK build tools identity drifted.")
        let buildToolsProperties = try buildTools.object("sourceProperties")
        try buildToolsProperties.requireKeys(["path", "sha256", "size"])
        _ = try fileDescription(buildToolsProperties, requiredPath: "build-tools/\(revision)/source.properties", label: "build tools source properties")
    }

    private static func validateFreezes(_ values: [Any]) throws {
        let expected = [("archive-source", "source-archive"), ("extract-source", "build-input-tree"),
                        ("observe-tool-identities", "build-input-tree"), ("install-web-dependencies", "build-input-tree"),
                        ("build-embedded-web", "build-input-tree"), ("assemble-android-aar", "build-input-tree"),
                        ("build-ios-package", "build-input-tree"), ("before-manifest", "build-input-tree")]
        try candidateRequire(values.count == expected.count, "Candidate input freezes are incomplete.")
        for (index, value) in values.enumerated() {
            let freeze = try JSONObject(value, label: "input freeze")
            try freeze.requireKeys(["after", "kind", "sha256"])
            try candidateRequire(freeze.string("after") == expected[index].0 && freeze.string("kind") == expected[index].1 &&
                ElementCallCandidateRequest.isLowercaseHex(freeze.string("sha256"), count: 64), "Candidate input freeze drifted.")
        }
    }

    static func validateTools(_ tools: JSONObject) throws {
        try tools.requireKeys(["binaries", "versions"])
        let versions = try tools.object("versions")
        try versions.requireKeys(["gradle", "java", "node", "pnpm", "swift"])
        let node = try validateTool(versions.object("node"), expectedRequirement: "24.13.1", label: "Node")
        try candidateRequire(node.observed == "v24.13.1", "The observed Node version does not match its requirement.")
        let pnpm = try validateTool(versions.object("pnpm"), expectedRequirement: "10.33.0", label: "pnpm")
        try candidateRequire(pnpm.observed == "10.33.0", "The observed pnpm version does not match its requirement.")
        let java = try validateTool(versions.object("java"), expectedRequirement: "17", label: "Java")
        try candidateRequire(java.observed.range(of: #"(?:^|\D)17(?:\D|$)"#, options: .regularExpression) != nil,
                             "The observed Java version does not satisfy Java 17.")
        let gradle = try validateTool(versions.object("gradle"), expectedRequirement: nil, label: "Gradle")
        try candidateRequire(isExactVersion(gradle.requirement) && gradle.observed.contains(gradle.requirement),
                             "The observed Gradle version does not match its exact wrapper requirement.")
        let swift = try validateTool(versions.object("swift"), expectedRequirement: nil, label: "Swift")
        let swiftMajor = swift.requirement.split(separator: ".").first.map(String.init) ?? ""
        try candidateRequire(isExactVersion(swift.requirement) &&
            swift.observed.range(of: "(?:^|\\D)\(NSRegularExpression.escapedPattern(for: swiftMajor))(?:\\D|$)",
                                 options: .regularExpression) != nil,
            "The observed Swift version does not satisfy its package tools requirement.")
        let binaries = try tools.object("binaries")
        try binaries.requireKeys(expectedBinaryKeys)
        for key in expectedBinaryKeys {
            let binary = try binaries.object(key)
            try binary.requireKeys(["path", "sha256", "size"])
            let path = try binary.string("path")
            if path.hasPrefix("/") {
                try ElementCallCandidatePath.validateRecordedAbsolute(path, label: "\(key) binary path")
            } else {
                try ElementCallCandidatePath.validateRelative(path)
            }
            try validateDigestAndSize(binary, label: "\(key) binary")
        }
    }

    static func validatePlatform(_ platform: JSONObject) throws {
        try platform.requireKeys(["os", "xcode"])
        let os = try platform.object("os")
        try os.requireKeys(["architecture", "buildVersion", "kernelRelease", "productVersion", "system"])
        try candidateRequire(os.string("system") == "darwin", "Candidate platform must be Darwin.")
        try candidateRequire(!os.string("architecture").isEmpty, "Candidate OS architecture is incomplete.")
        for key in ["buildVersion", "kernelRelease", "productVersion"] {
            let value = try os.string(key)
            try candidateRequire(!value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                                 "Candidate OS metadata is incomplete.")
        }
        let xcode = try platform.object("xcode")
        try xcode.requireKeys(["developerDirectory", "observed", "swiftExecutable"])
        try ElementCallCandidatePath.validateRecordedAbsolute(xcode.string("developerDirectory"), label: "Xcode directory")
        try ElementCallCandidatePath.validateRecordedAbsolute(xcode.string("swiftExecutable"), label: "Swift executable")
        try candidateRequire(xcode.string("observed").range(of: #"^Xcode .+\nBuild version .+$"#, options: .regularExpression) != nil,
                             "Candidate Xcode observation is incomplete.")
    }

    private static func validateCommands(_ transcript: JSONObject,
                                         environmentSHA: String,
                                         context: ExecutionContext,
                                         builder: JSONObject,
                                         platform: JSONObject,
                                         source: JSONObject,
                                         tools: JSONObject) throws {
        try transcript.requireKeys(["records", "sha256"])
        let records = try transcript.array("records")
        try candidateRequire(records.count == expectedCommandNames.count, "Candidate command lifecycle is incomplete.")
        let specs = try commandSpecs(context: context, builder: builder, platform: platform, source: source, tools: tools)
        var previous = commandStart
        for (index, rawRecord) in records.enumerated() {
            let record = try JSONObject(rawRecord, label: "command record \(index)")
            try record.requireKeys(["argv", "cwd", "delegated", "environmentSha256", "launcher", "name", "networkBoundary",
                                    "observation", "previousSha256", "sha256", "subject"])
            let spec = specs[index]
            let subject = try commandTool(tools, key: spec.subject)
            let launcher = try commandTool(tools, key: spec.sandboxed ? "sandboxExec" : spec.subject)
            let expectedArguments = try spec.sandboxed
                ? [launcher.string("path"), "-p", sandboxProfile, subject.string("path")] + spec.arguments
                : [subject.string("path")] + spec.arguments
            try candidateRequire(record.string("name") == expectedCommandNames[index] && record.string("name") == spec.name &&
                record.stringArray("argv") == expectedArguments && record.string("cwd") == spec.cwd &&
                record.string("environmentSha256") == environmentSHA && record.string("previousSha256") == previous &&
                record.string("networkBoundary") == (spec.sandboxed ? sandboxBoundary : gradleBoundary),
                "Candidate lifecycle command drifted at record \(index).")
            try candidateRequire(JSONEquality.equals(record.raw["launcher"]!, launcher.raw) &&
                JSONEquality.equals(record.raw["subject"]!, subject.raw), "Candidate command tool identity drifted at record \(index).")
            let delegated = try record.array("delegated")
            let expectedDelegated = try spec.delegated.map { try commandTool(tools, key: $0).raw }
            try candidateRequire(JSONEquality.equals(delegated, expectedDelegated), "Candidate delegated tools drifted at record \(index).")
            try validateCommandObservation(record.raw["observation"]!, index: index)
            try candidateRequire(JSONEquality.equals(record.raw["observation"]!, spec.observation), "Candidate observation drifted at record \(index).")
            let payload: [String: Any] = [
                "argv": record.raw["argv"]!, "cwd": record.raw["cwd"]!, "delegated": delegated,
                "environmentSha256": record.raw["environmentSha256"]!, "launcher": record.raw["launcher"]!,
                "name": record.raw["name"]!, "networkBoundary": record.raw["networkBoundary"]!,
                "observation": record.raw["observation"]!, "previousSha256": previous, "subject": record.raw["subject"]!
            ]
            let digest = try sha256(canonicalJSON(payload))
            try candidateRequire(record.string("sha256") == digest, "Candidate command chain drifted at record \(index).")
            previous = digest
        }
        try candidateRequire(transcript.string("sha256") == previous, "Candidate command transcript digest drifted.")
    }

    private static func commandSpecs(context: ExecutionContext,
                                     builder: JSONObject,
                                     platform: JSONObject,
                                     source: JSONObject,
                                     tools: JSONObject) throws -> [CommandSpec] {
        let binaries = try tools.object("binaries")
        let versions = try tools.object("versions")
        let sourceDirectory = context.exportedSource
        let android = URL(filePath: sourceDirectory).appending(path: "embedded/android").path
        let ios = URL(filePath: sourceDirectory).appending(path: "embedded/ios").path
        func sandboxed(_ name: String, _ subject: String, _ arguments: [String], _ cwd: String, _ observation: Any = NSNull(), _ delegated: [String] = []) -> CommandSpec {
            CommandSpec(name: name, subject: subject, arguments: arguments, cwd: cwd, observation: observation, delegated: delegated, sandboxed: true)
        }
        func gradle(_ name: String, _ arguments: [String], _ observation: Any = NSNull()) -> CommandSpec {
            CommandSpec(name: name, subject: "mise", arguments: arguments, cwd: android, observation: observation,
                        delegated: ["java", "gradleDistribution", "gradleWrapperJar", "gradleWrapperScript"], sandboxed: false)
        }
        func git(_ name: String, _ root: String, _ arguments: [String], _ observation: String) -> CommandSpec {
            sandboxed(name, "git", ["-C", root] + arguments, context.builderRoot, observation)
        }
        let networkProbe = "const net = require('node:net');const server = net.createServer();server.once('error', error => process.exit(error.code === 'EPERM' ? 0 : 2));server.listen(0, '127.0.0.1', () => { server.close(); process.exit(1); });"
        return try [
            git("validate-builder-commit", context.builderRoot, ["rev-parse", "HEAD"], builder.string("commit")),
            git("validate-builder-status", context.builderRoot, ["status", "--porcelain", "--untracked-files=all"], ""),
            git("validate-builder-tree", context.builderRoot, ["rev-parse", "HEAD^{tree}"], builder.string("tree")),
            git("validate-source-commit", context.sourceRoot, ["rev-parse", "HEAD"], source.string("commit")),
            git("validate-source-status", context.sourceRoot, ["status", "--porcelain", "--untracked-files=all"], ""),
            git("validate-source-tree", context.sourceRoot, ["rev-parse", "HEAD^{tree}"], source.string("tree")),
            sandboxed("archive-source", "git", ["-C", context.sourceRoot, "archive", "--format=tar", "--output=\(context.sourceArchive)", source.string("commit")], context.builderRoot),
            git("revalidate-source-commit", context.sourceRoot, ["rev-parse", "HEAD"], source.string("commit")),
            git("revalidate-source-status", context.sourceRoot, ["status", "--porcelain", "--untracked-files=all"], ""),
            git("revalidate-source-tree", context.sourceRoot, ["rev-parse", "HEAD^{tree}"], source.string("tree")),
            sandboxed("extract-source", "tar", ["-xf", context.sourceArchive, "-C", sourceDirectory], context.builderRoot),
            sandboxed("resolve-pnpm-with-mise", "mise", ["where", "pnpm@10.33.0"], sourceDirectory,
                      URL(filePath: binaries.object("pnpm").string("path")).deletingLastPathComponent().path),
            sandboxed("resolve-java-with-mise", "mise", ["where", "java@17"], sourceDirectory,
                      URL(filePath: binaries.object("java").string("path")).deletingLastPathComponent().deletingLastPathComponent().path),
            sandboxed("resolve-swift-with-xcrun", "xcrun", ["--find", "swift"], sourceDirectory, binaries.object("swift").string("path")),
            sandboxed("resolve-xcodebuild-with-xcrun", "xcrun", ["--find", "xcodebuild"], sourceDirectory, binaries.object("xcodebuild").string("path")),
            sandboxed("prove-network-sandbox", "node", ["--eval", networkProbe], sourceDirectory, ""),
            gradle("observe-gradle-version", ["exec", "java@17", "--", "./gradlew", "--version", "--no-daemon", "--offline"], versions.object("gradle").string("observed")),
            sandboxed("observe-java-version", "java", ["-version"], sourceDirectory, versions.object("java").string("observed")),
            sandboxed("observe-pnpm-version", "pnpm", ["--version"], sourceDirectory, versions.object("pnpm").string("observed")),
            sandboxed("observe-swift-version", "swift", ["--version"], sourceDirectory, versions.object("swift").string("observed")),
            sandboxed("observe-os-build-version", "swVers", ["-buildVersion"], sourceDirectory, platform.object("os").string("buildVersion")),
            sandboxed("observe-os-product-version", "swVers", ["-productVersion"], sourceDirectory, platform.object("os").string("productVersion")),
            sandboxed("observe-xcode-developer-directory", "xcodeSelect", ["-p"], sourceDirectory, platform.object("xcode").string("developerDirectory")),
            sandboxed("observe-xcode-version", "xcodebuild", ["-version"], sourceDirectory, platform.object("xcode").string("observed")),
            sandboxed("install-web-dependencies", "mise", ["exec", "node@24.13.1", "pnpm@10.33.0", "--", "pnpm", "install", "--frozen-lockfile", "--offline"], sourceDirectory, NSNull(), ["node", "pnpm"]),
            sandboxed("build-embedded-web", "mise", ["exec", "node@24.13.1", "pnpm@10.33.0", "--", "pnpm", "build:embedded:production"], sourceDirectory, NSNull(), ["node", "pnpm"]),
            gradle("assemble-android-aar", ["exec", "java@17", "--", "./gradlew", ":lib:assembleRelease", "--no-daemon", "--offline"]),
            sandboxed("build-ios-package", "xcrun", ["swift", "build", "--package-path", ios, "--disable-automatic-resolution", "--disable-sandbox"], sourceDirectory, NSNull(), ["swift"])
        ]
    }

    private static func commandTool(_ tools: JSONObject, key: String) throws -> JSONObject {
        let binary = try tools.object("binaries").object(key)
        return try JSONObject(["key": key, "path": binary.string("path"), "sha256": binary.string("sha256"), "size": binary.integer("size")], label: key)
    }

    private static func validatePolicy(_ object: JSONObject, expected: [String: [String]], label: String) throws {
        try object.requireKeys(Set(expected.keys))
        for (key, values) in expected {
            try candidateRequire(object.stringArray(key) == values, "\(label) drifted.")
        }
    }

    private static func validateGitIdentity(_ object: JSONObject, label: String) throws -> String {
        try object.requireKeys(["commit", "tree"])
        let commit = try object.string("commit")
        try candidateRequire(ElementCallCandidateRequest.isLowercaseHex(commit, count: 40) &&
            ElementCallCandidateRequest.isLowercaseHex(object.string("tree"), count: 40), "The \(label) Git identity is invalid.")
        return commit
    }

    static func validateVersion(_ version: String, sourceCommit: String) throws {
        try candidateRequire(version.range(of: #"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-junchat\.[0-9a-f]{12}$"#,
                                           options: .regularExpression) != nil && version.hasSuffix(String(sourceCommit.prefix(12))),
                             "The Element Call candidate version does not match its source commit.")
    }

    private static func validateTool(_ tool: JSONObject,
                                     expectedRequirement: String?,
                                     label: String) throws -> (requirement: String, observed: String) {
        try tool.requireKeys(["observed", "requirement"])
        let requirement = try tool.string("requirement")
        let observed = try tool.string("observed")
        try candidateRequire(!requirement.isEmpty && !observed.isEmpty && observed.utf8.count <= 4096 &&
            observed == observed.trimmingCharacters(in: .whitespacesAndNewlines),
            "Candidate \(label) version is missing.")
        if let expectedRequirement {
            try candidateRequire(requirement == expectedRequirement, "Candidate \(label) version drifted.")
        }
        return (requirement, observed)
    }

    private static func isExactVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+\.[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func validateCommandObservation(_ value: Any, index: Int) throws {
        if value is NSNull {
            return
        }
        guard let observation = value as? String, observation.utf8.count <= 16384,
              observation == observation.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ElementCallCandidateError.validation("Candidate command observation drifted at record \(index).")
        }
    }

    private static func validateDigestAndSize(_ object: JSONObject, label: String) throws {
        try candidateRequire(ElementCallCandidateRequest.isLowercaseHex(object.string("sha256"), count: 64) &&
            (object.integer("size")) >= 0, "The \(label) digest or size is invalid.")
    }

    private static func fileDescription(_ object: JSONObject, requiredPath: String, label: String) throws -> FileDescription {
        try object.requireKeys(["path", "sha256", "size"])
        return try fileDescriptionFields(object, requiredPath: requiredPath, label: label)
    }

    private static func fileDescriptionFields(_ object: JSONObject,
                                              requiredPath: String,
                                              label: String) throws -> FileDescription {
        let path = try object.string("path")
        try candidateRequire(path == requiredPath, "The \(label) path drifted.")
        try ElementCallCandidatePath.validateRelative(path)
        try validateDigestAndSize(object, label: label)
        return try FileDescription(path: path, sha256: object.string("sha256"), size: object.integer("size"))
    }

    private static func treeDescription(_ object: JSONObject, requiredPath: String, label: String) throws -> TreeDescription {
        try object.requireKeys(["files", "path", "treeSha256"])
        return try treeFields(object, requiredPath: requiredPath, label: label)
    }

    static func treeFields(_ object: JSONObject, requiredPath: String?, label: String) throws -> TreeDescription {
        let path = try requiredPath.map { required -> String in
            let actual = try object.string("path")
            try candidateRequire(actual == required, "The \(label) path drifted.")
            try ElementCallCandidatePath.validateRelative(actual)
            return actual
        } ?? ""
        let files = try object.array("files").enumerated().map { index, raw -> FileDescription in
            let file = try JSONObject(raw, label: "\(label) file \(index)")
            return try fileDescription(file, requiredPath: file.string("path"), label: "\(label) file \(index)")
        }
        try candidateRequire(!files.isEmpty && zip(files, files.dropFirst()).allSatisfy { utf8Less($0.path, $1.path) },
                             "The \(label) files must be nonempty, unique, and UTF-8 sorted.")
        let digest = try object.string("treeSha256")
        try candidateRequire(ElementCallCandidateRequest.isLowercaseHex(digest, count: 64) && treeSHA256(files) == digest,
                             "The \(label) descriptor tree SHA-256 drifted.")
        return TreeDescription(path: path, treeSHA256: digest, files: files)
    }

    static func describeTree(_ root: URL, label: String) throws -> TreeDescription {
        let snapshots = try snapshotTree(root, label: label)
        let files = snapshots.map { FileDescription(path: $0.path, sha256: sha256($0.data), size: Int64($0.data.count)) }
        return TreeDescription(path: "", treeSHA256: treeSHA256(files), files: files)
    }

    private static func verifyTree(_ root: URL, expected: TreeDescription, label: String) throws -> [ElementCallCandidateFileSnapshot] {
        let snapshots = try snapshotTree(root, label: label)
        let actual = snapshots.map { FileDescription(path: $0.path, sha256: sha256($0.data), size: Int64($0.data.count)) }
        try candidateRequire(actual == expected.files && treeSHA256(actual) == expected.treeSHA256,
                             "The retained \(label) does not match its manifest.")
        return snapshots
    }

    private static func snapshotTree(_ root: URL, label: String) throws -> [ElementCallCandidateFileSnapshot] {
        _ = try ElementCallCandidatePath.validateExisting(root, kind: .directory, label: label)
        var snapshots = [ElementCallCandidateFileSnapshot]()
        func visit(_ directory: URL) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: []).sorted { utf8Less($0.lastPathComponent, $1.lastPathComponent) }
            for child in children {
                var information = stat()
                try candidateRequire(lstat(child.path, &information) == 0, "The \(label) changed during validation.")
                try candidateRequire(information.st_mode & S_IFMT != S_IFLNK, "The \(label) cannot contain symlinks.")
                if information.st_mode & S_IFMT == S_IFDIR {
                    try visit(child)
                } else {
                    try candidateRequire(information.st_mode & S_IFMT == S_IFREG, "The \(label) contains an unsupported entry.")
                    let relative = String(child.path.dropFirst(root.path.count + 1))
                    try ElementCallCandidatePath.validateRelative(relative)
                    try snapshots.append(.init(path: relative, data: readFile(child, maximumBytes: maximumArtifactBytes, label: "\(label) file")))
                }
            }
        }
        try visit(root)
        snapshots.sort { utf8Less($0.path, $1.path) }
        return snapshots
    }

    private static func readFile(_ url: URL, maximumBytes: Int64, label: String) throws -> Data {
        _ = try ElementCallCandidatePath.validateExisting(url, kind: .file, label: label)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        try candidateRequire(descriptor >= 0, "Unable to open \(label) without following links.")
        defer { close(descriptor) }
        var information = stat()
        try candidateRequire(fstat(descriptor, &information) == 0 && information.st_mode & S_IFMT == S_IFREG,
                             "The opened \(label) is not a regular file.")
        try candidateRequire(information.st_size >= 0 && information.st_size <= maximumBytes,
                             "The \(label) exceeds the permitted size.")
        var data = Data(count: Int(information.st_size))
        let dataCount = data.count
        var offset = 0
        while offset < dataCount {
            let count = data.withUnsafeMutableBytes { buffer in
                read(descriptor, buffer.baseAddress!.advanced(by: offset), dataCount - offset)
            }
            try candidateRequire(count > 0, "The \(label) changed while its byte snapshot was read.")
            offset += count
        }
        var finalInformation = stat()
        try candidateRequire(fstat(descriptor, &finalInformation) == 0 && finalInformation.st_size == information.st_size,
                             "The \(label) changed while its byte snapshot was read.")
        return data
    }

    private static func treeSHA256(_ files: [FileDescription]) -> String {
        let values: [[String: Any]] = files.map { ["path": $0.path, "sha256": $0.sha256, "size": $0.size] }
        return sha256(try! canonicalJSON(values))
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func utf8Less(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    struct JSONObject {
        let raw: [String: Any]
        let label: String

        init(_ value: Any, label: String) throws {
            guard let raw = value as? [String: Any] else { throw ElementCallCandidateError.validation("The \(label) must be a JSON object.") }
            self.raw = raw
            self.label = label
        }

        static func decode(_ data: Data, label: String) throws -> Self {
            do { return try Self(JSONSerialization.jsonObject(with: data, options: []), label: label) }
            catch let error as ElementCallCandidateError { throw error }
            catch { throw ElementCallCandidateError.validation("The \(label) is not valid JSON: \(error.localizedDescription)") }
        }

        func requireKeys(_ expected: Set<String>) throws {
            let actual = Set(raw.keys)
            try candidateRequire(actual == expected,
                                 "The \(label) fields do not match the trusted candidate schema; expected \(expected.sorted()), got \(actual.sorted()).")
        }

        func object(_ key: String) throws -> Self {
            try Self(raw[key] as Any, label: key)
        }

        func array(_ key: String) throws -> [Any] {
            guard let value = raw[key] as? [Any] else { throw ElementCallCandidateError.validation("The \(key) field must be an array.") }
            return value
        }

        func string(_ key: String) throws -> String {
            guard let value = raw[key] as? String else { throw ElementCallCandidateError.validation("The \(key) field must be a string.") }
            return value
        }

        func stringArray(_ key: String) throws -> [String] {
            let values = try array(key)
            guard let strings = values as? [String] else { throw ElementCallCandidateError.validation("The \(key) field must be a string array.") }
            return strings
        }

        func bool(_ key: String) throws -> Bool {
            guard let value = raw[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw ElementCallCandidateError.validation("The \(key) field must be a boolean.")
            }
            return value.boolValue
        }

        func integer(_ key: String) throws -> Int64 {
            try ElementCallCandidateJSON.safeInteger(raw[key], label: key)
        }
    }

    private enum JSONEquality {
        static func equals(_ left: Any, _ right: Any) throws -> Bool {
            try canonicalJSON(left) == canonicalJSON(right)
        }
    }
}

struct StagedElementCallCandidate {
    let rootURL: URL
    let packageURL: URL
}

enum ElementCallCandidateStaging {
    static func stage(_ package: ElementCallCandidatePackageSnapshot, under parent: URL) throws -> StagedElementCallCandidate {
        _ = try ElementCallCandidatePath.validateExisting(parent, kind: .directory, label: "candidate temporary parent")
        let root = parent.appending(path: "junchat-element-call-ios-\(UUID().uuidString)")
        try createDirectory(root)
        do {
            let packageURL = root.appending(path: "EmbeddedElementCall")
            try createDirectory(packageURL)
            var seen = Set<String>()
            for file in package.files {
                try ElementCallCandidatePath.validateRelative(file.path)
                try candidateRequire(seen.insert(file.path).inserted, "The verified package snapshot contains duplicate paths.")
                let destination = packageURL.appending(path: file.path)
                var directory = packageURL
                for component in file.path.split(separator: "/").dropLast() {
                    directory.append(path: String(component))
                    if !FileManager.default.fileExists(atPath: directory.path) {
                        try createDirectory(directory)
                    } else {
                        _ = try ElementCallCandidatePath.validateExisting(directory, kind: .directory, label: "staging directory")
                    }
                }
                try write(file.data, to: destination)
            }
            return StagedElementCallCandidate(rootURL: root, packageURL: packageURL)
        } catch {
            let operationError = error
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                throw ElementCallCandidateError.validation("Unable to remove failed candidate staging root \(root.path). " +
                    "Primary failure: \(operationError.localizedDescription). Cleanup failure: \(error.localizedDescription).")
            }
            throw operationError
        }
    }

    private static func createDirectory(_ url: URL) throws {
        try candidateRequire(mkdir(url.path, 0o700) == 0, "Unable to create private candidate directory: \(url.path).")
        try candidateRequire(chmod(url.path, 0o700) == 0, "Unable to secure private candidate directory: \(url.path).")
        var information = stat()
        try candidateRequire(lstat(url.path, &information) == 0 && information.st_mode & S_IFMT == S_IFDIR &&
            information.st_mode & 0o777 == 0o700, "Candidate staging directories must use mode 0700.")
    }

    private static func write(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try candidateRequire(descriptor >= 0, "Unable to create private staged candidate file: \(url.path).")
        defer { close(descriptor) }
        let dataCount = data.count
        var offset = 0
        while offset < dataCount {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), dataCount - offset)
            }
            try candidateRequire(count > 0, "Unable to write the staged candidate file atomically.")
            offset += count
        }
        try candidateRequire(fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0,
                             "Unable to secure the staged candidate file.")
    }
}
