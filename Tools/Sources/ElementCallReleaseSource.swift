/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import Foundation

enum ElementCallReleaseSource {
    struct Lock: Equatable {
        let sourceCommit: String
        let sourceTree: String
        let version: String
        let manifestSHA256: String
        let packagePath: String
        let packageTreeSHA256: String
        let rtcConfigurationAuthority: String
    }

    private static let lockPath = "ElementCall.release.json"
    private static let releaseSchema = "junchat.element-call-ios-release/v1"
    private static let candidateSchema = "junchat.element-call-candidate/v4"
    private static let sourceRepository = "https://github.com/iaMeteor/junchat-element-call.git"
    private static let packagePath = "Vendor/EmbeddedElementCall"
    private static let rtcConfigurationAuthority = "Vendor/EmbeddedElementCall/Sources/dist/config.json"
    private static let maximumLockBytes = 64 * 1024

    static func validate(repositoryURL: URL) throws -> Lock {
        let lockURL = try ElementCallCandidatePath.validateExisting(repositoryURL.appending(path: lockPath),
                                                                    kind: .file,
                                                                    label: "Element Call release lock")
        let data = try Data(contentsOf: lockURL)
        try releaseRequire(data.count <= maximumLockBytes, "The Element Call release lock is too large.")
        try ElementCallCandidateJSON.validateUniqueKeys(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElementCallCandidateError.validation("The Element Call release lock must be a JSON object.")
        }
        try requireKeys(root,
                        expected: ["candidate", "package", "rtcConfigurationAuthority", "schema", "source"],
                        label: "Element Call release lock")
        try releaseRequire(root["schema"] as? String == releaseSchema,
                           "The Element Call release lock schema is unsupported.")
        try releaseRequire(root["rtcConfigurationAuthority"] as? String == rtcConfigurationAuthority,
                           "The Element Call RTC configuration authority drifted.")

        let source = try object(root["source"], label: "Element Call release source")
        try requireKeys(source, expected: ["commit", "repository", "tree"], label: "Element Call release source")
        let sourceCommit = try string(source["commit"], label: "Element Call source commit")
        let sourceTree = try string(source["tree"], label: "Element Call source tree")
        try releaseRequire(source["repository"] as? String == sourceRepository,
                           "The Element Call source repository drifted.")
        try releaseRequire(ElementCallCandidateRequest.isLowercaseHex(sourceCommit, count: 40) &&
            ElementCallCandidateRequest.isLowercaseHex(sourceTree, count: 40),
            "The Element Call source identity is invalid.")

        let candidate = try object(root["candidate"], label: "Element Call release candidate")
        try requireKeys(candidate, expected: ["manifestSha256", "schema", "version"], label: "Element Call release candidate")
        let version = try string(candidate["version"], label: "Element Call candidate version")
        let manifestSHA256 = try string(candidate["manifestSha256"], label: "Element Call candidate manifest SHA-256")
        try releaseRequire(candidate["schema"] as? String == candidateSchema,
                           "The Element Call candidate schema drifted.")
        try releaseRequire(ElementCallCandidateRequest.isLowercaseHex(manifestSHA256, count: 64),
                           "The Element Call candidate manifest SHA-256 is invalid.")
        try ElementCallCandidateManifest.validateVersion(version, sourceCommit: sourceCommit)

        let package = try object(root["package"], label: "Element Call release package")
        try requireKeys(package, expected: ["path", "treeSha256"], label: "Element Call release package")
        let packageTreeSHA256 = try string(package["treeSha256"], label: "Element Call package tree SHA-256")
        try releaseRequire(package["path"] as? String == packagePath &&
            ElementCallCandidateRequest.isLowercaseHex(packageTreeSHA256, count: 64),
            "The Element Call release package identity drifted.")

        let packageURL = repositoryURL.appending(path: packagePath)
        let packageTree = try ElementCallCandidateManifest.describeTree(packageURL, label: "vendored Element Call package")
        try releaseRequire(packageTree.treeSHA256 == packageTreeSHA256,
                           "The vendored Element Call package does not match its release lock.")
        _ = try ElementCallCandidatePath.validateExisting(repositoryURL.appending(path: rtcConfigurationAuthority),
                                                          kind: .file,
                                                          label: "Element Call RTC configuration authority")

        return Lock(sourceCommit: sourceCommit,
                    sourceTree: sourceTree,
                    version: version,
                    manifestSHA256: manifestSHA256,
                    packagePath: packagePath,
                    packageTreeSHA256: packageTreeSHA256,
                    rtcConfigurationAuthority: rtcConfigurationAuthority)
    }

    private static func object(_ value: Any?, label: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw ElementCallCandidateError.validation("The \(label) must be a JSON object.")
        }
        return value
    }

    private static func string(_ value: Any?, label: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw ElementCallCandidateError.validation("The \(label) must be a nonempty string.")
        }
        return value
    }

    private static func requireKeys(_ object: [String: Any], expected: Set<String>, label: String) throws {
        try releaseRequire(Set(object.keys) == expected, "The \(label) fields drifted.")
    }
}

private func releaseRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ElementCallCandidateError.validation(message) }
}
