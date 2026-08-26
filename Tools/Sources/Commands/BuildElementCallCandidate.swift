/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import ArgumentParser
import Darwin
import Foundation
import Yams

enum ElementCallCandidateProjectSpec {
    struct Inspection {
        let elementCallPath: String?
        let elementCallURL: String?
        let elementCallExactVersion: String?
        let hasPostGenerationCommand: Bool
        let replacesElementXPreBuildScripts: Bool
        let replacesElementXPostBuildScripts: Bool
        let packageKeys: Set<String>
        let packagePaths: [String: String]
        let targetBaseSettings: [String: [String: String]]
        let targetEntitlementPaths: [String: String]
    }

    static func validateDefault(_ yaml: String) throws {
        let inspection = try inspect(yaml)
        try candidateProjectRequire(inspection.packageKeys == ["path"] &&
            inspection.elementCallPath == "Vendor/EmbeddedElementCall" &&
            inspection.elementCallURL == nil && inspection.elementCallExactVersion == nil,
            "The default EmbeddedElementCall dependency must remain the release-locked vendored package.")
    }

    static func make(defaultProjectYAML: String,
                     stagedPackageURL: URL,
                     repositoryURL: URL,
                     developmentSigning: Bool = false) throws -> String {
        try validateDefault(defaultProjectYAML)
        try ElementCallCandidatePath.validateRecordedAbsolute(stagedPackageURL.path, label: "staged Element Call package")
        let targetBaseSettings = try protectedTargetBaseSettings(repositoryURL: repositoryURL,
                                                                 developmentSigning: developmentSigning)
        let targetEntitlementPaths = try protectedTargetEntitlementPaths(repositoryURL: repositoryURL)
        guard var node = try Yams.compose(yaml: defaultProjectYAML), var root = node.mapping,
              var packagesNode = root["packages"], var packages = packagesNode.mapping,
              var optionsNode = root["options"], var options = optionsNode.mapping else {
            throw ElementCallCandidateError.validation("Unable to parse the default XcodeGen project structure.")
        }
        packages["EmbeddedElementCall"] = ["path": Node(stagedPackageURL.path)]
        guard let compoundNode = packages["Compound"],
              let compound = compoundNode.mapping,
              compound.keys.compactMap(\.string) == ["path"],
              compound["path"]?.string == "compound-ios" else {
            throw ElementCallCandidateError.validation("The default Compound dependency must remain the local compound-ios package.")
        }
        let compoundURL = repositoryURL.appending(path: "compound-ios")
        _ = try ElementCallCandidatePath.validateExisting(compoundURL, kind: .directory,
                                                          label: "protected Compound package")
        _ = try ElementCallCandidatePath.validateExisting(compoundURL.appending(path: "Package.swift"), kind: .file,
                                                          label: "protected Compound package manifest")
        packages["Compound"] = ["path": Node(compoundURL.path)]
        packagesNode.mapping = packages
        root["packages"] = packagesNode
        options["postGenCommand"] = nil
        optionsNode.mapping = options
        root["options"] = optionsNode

        var targetsNode = root["targets"] ?? Node([] as [(Node, Node)])
        try candidateProjectRequire(targetsNode.mapping != nil,
                                    "The default XcodeGen targets override must be a mapping.")
        var elementXNode = targetsNode["ElementX"] ?? Node([] as [(Node, Node)])
        try candidateProjectRequire(elementXNode.mapping != nil,
                                    "The default ElementX target override must be a mapping.")
        elementXNode["preBuildScripts:REPLACE"] = Node([] as [Node])
        elementXNode["postBuildScripts:REPLACE"] = Node([] as [Node])
        targetsNode["ElementX"] = elementXNode

        for targetName in Set(targetBaseSettings.keys).union(targetEntitlementPaths.keys).sorted() {
            var targetNode = targetsNode[targetName] ?? Node([] as [(Node, Node)])
            try candidateProjectRequire(targetNode.mapping != nil,
                                        "The transient \(targetName) target override must be a mapping.")
            var settingsNode = targetNode["settings"] ?? Node([] as [(Node, Node)])
            try candidateProjectRequire(settingsNode.mapping != nil,
                                        "The transient \(targetName) settings override must be a mapping.")
            var baseNode = settingsNode["base"] ?? Node([] as [(Node, Node)])
            try candidateProjectRequire(baseNode.mapping != nil,
                                        "The transient \(targetName) base settings override must be a mapping.")
            for (settingName, value) in targetBaseSettings[targetName, default: [:]].sorted(by: { $0.key < $1.key }) {
                baseNode[settingName] = Node(value)
            }
            settingsNode["base"] = baseNode
            targetNode["settings"] = settingsNode
            if let entitlementPath = targetEntitlementPaths[targetName] {
                var entitlementsNode = targetNode["entitlements"] ?? Node([] as [(Node, Node)])
                try candidateProjectRequire(entitlementsNode.mapping != nil,
                                            "The transient \(targetName) entitlements override must be a mapping.")
                entitlementsNode["path"] = Node(entitlementPath)
                targetNode["entitlements"] = entitlementsNode
            }
            targetsNode[targetName] = targetNode
        }
        root["targets"] = targetsNode

        node.mapping = root
        let yaml = try Yams.serialize(node: node)
        let inspection = try inspect(yaml)
        try candidateProjectRequire(inspection.packageKeys == ["path"] && inspection.elementCallPath == stagedPackageURL.path &&
            inspection.elementCallURL == nil && inspection.elementCallExactVersion == nil && !inspection.hasPostGenerationCommand &&
            inspection.replacesElementXPreBuildScripts && inspection.replacesElementXPostBuildScripts &&
            inspection.packagePaths == ["Compound": compoundURL.path, "EmbeddedElementCall": stagedPackageURL.path] &&
            inspection.targetBaseSettings == targetBaseSettings &&
            inspection.targetEntitlementPaths == targetEntitlementPaths,
            "The transient XcodeGen spec did not isolate the local Element Call package.")
        return yaml
    }

    private static func protectedTargetBaseSettings(repositoryURL: URL,
                                                    developmentSigning: Bool) throws -> [String: [String: String]] {
        let paths: [(String, String, String, ElementCallCandidatePath.Kind)] = [
            ("ElementX", "DEVELOPMENT_ASSET_PATHS", "DevelopmentAssets/Media", .directory),
            ("ElementX", "INFOPLIST_FILE", "ElementX/SupportingFiles/Info.plist", .file),
            ("ElementX", "SWIFT_OBJC_BRIDGING_HEADER", "ElementX/SupportingFiles/ElementX-Bridging-Header.h", .file),
            ("NSE", "INFOPLIST_FILE", "NSE/SupportingFiles/Info.plist", .file),
            ("ShareExtension", "INFOPLIST_FILE", "ShareExtension/SupportingFiles/Info.plist", .file)
        ]
        var settings = [String: [String: String]]()
        for (target, setting, relativePath, kind) in paths {
            let url = repositoryURL.appending(path: relativePath)
            _ = try ElementCallCandidatePath.validateExisting(url, kind: kind,
                                                              label: "protected \(target) \(setting) path")
            settings[target, default: [:]][setting] = url.path
        }
        if developmentSigning {
            let signingSettings = [
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_STYLE": "Automatic"
            ]
            for targetName in ["ElementX", "NSE", "ShareExtension"] {
                settings[targetName, default: [:]].merge(signingSettings) { _, signed in signed }
            }
        }
        return settings
    }

    private static func protectedTargetEntitlementPaths(repositoryURL: URL) throws -> [String: String] {
        let paths = [
            "ElementX": "ElementX/SupportingFiles/ElementX.entitlements",
            "NSE": "NSE/SupportingFiles/NSE.entitlements",
            "ShareExtension": "ShareExtension/SupportingFiles/ShareExtension.entitlements"
        ]
        return try paths.mapValues { relativePath in
            let url = repositoryURL.appending(path: relativePath)
            _ = try ElementCallCandidatePath.validateExisting(url, kind: .file,
                                                              label: "protected target entitlements path")
            return url.path
        }
    }

    static func inspect(_ yaml: String) throws -> Inspection {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              let packages = root["packages"] as? [String: Any],
              let elementCall = packages["EmbeddedElementCall"] as? [String: Any],
              let options = root["options"] as? [String: Any] else {
            throw ElementCallCandidateError.validation("The XcodeGen spec does not contain its expected structured fields.")
        }
        let elementX = (root["targets"] as? [String: Any])?["ElementX"] as? [String: Any]
        let preBuildScripts = elementX?["preBuildScripts:REPLACE"] as? [Any]
        let postBuildScripts = elementX?["postBuildScripts:REPLACE"] as? [Any]
        let packagePaths = packages.compactMapValues { ($0 as? [String: Any])?["path"] as? String }
        var targetBaseSettings = [String: [String: String]]()
        var targetEntitlementPaths = [String: String]()
        for (name, value) in root["targets"] as? [String: Any] ?? [:] {
            guard let target = value as? [String: Any],
                  let settings = target["settings"] as? [String: Any],
                  let base = settings["base"] as? [String: Any] else { continue }
            targetBaseSettings[name] = base.compactMapValues { $0 as? String }
            if let entitlements = target["entitlements"] as? [String: Any],
               let path = entitlements["path"] as? String {
                targetEntitlementPaths[name] = path
            }
        }
        return Inspection(elementCallPath: elementCall["path"] as? String,
                          elementCallURL: elementCall["url"] as? String,
                          elementCallExactVersion: elementCall["exactVersion"] as? String,
                          hasPostGenerationCommand: options["postGenCommand"] != nil,
                          replacesElementXPreBuildScripts: preBuildScripts?.isEmpty == true,
                          replacesElementXPostBuildScripts: postBuildScripts?.isEmpty == true,
                          packageKeys: Set(elementCall.keys),
                          packagePaths: packagePaths,
                          targetBaseSettings: targetBaseSettings,
                          targetEntitlementPaths: targetEntitlementPaths)
    }
}

enum ElementCallCandidatePackageIdentity {
    static func validate(dumpPackageJSON: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: dumpPackageJSON) as? [String: Any],
              root["name"] as? String == "EmbeddedElementCall",
              let products = root["products"] as? [[String: Any]], products.count == 1,
              let productName = products[0]["name"] as? String, productName == "EmbeddedElementCall",
              products[0]["targets"] as? [String] == ["EmbeddedElementCall"],
              let productType = products[0]["type"] as? [String: Any], productType["library"] as? [String] == ["automatic"],
              let targets = root["targets"] as? [[String: Any]], targets.count == 1,
              targets[0]["name"] as? String == "EmbeddedElementCall", targets[0]["type"] as? String == "regular",
              (targets[0]["dependencies"] as? [Any])?.isEmpty == true,
              let resources = targets[0]["resources"] as? [[String: Any]], resources.count == 1,
              resources[0]["path"] as? String == "../dist",
              let rule = resources[0]["rule"] as? [String: Any], rule["copy"] is [String: Any] else {
            throw ElementCallCandidateError.validation("The staged Swift package identity is not exactly EmbeddedElementCall.")
        }
    }
}

enum ElementCallCandidatePackageResolution {
    private static let elementCallIdentity = "element-call-swift"

    static func validateRelease(_ data: Data) throws {
        let lock = try decode(data, label: "release Package.resolved")
        try candidateProjectRequire(lock.version == 3 && ElementCallCandidateRequest.isLowercaseHex(lock.originHash, count: 64),
                                    "The release Package.resolved metadata is invalid.")
        try candidateProjectRequire(lock.pins.allSatisfy { try identity(of: $0) != elementCallIdentity },
                                    "The release Package.resolved still contains the obsolete remote Element Call pin.")
    }

    static func validate(publicData: Data, candidateData: Data) throws {
        let publicLock = try decode(publicData, label: "public Package.resolved")
        let candidateLock = try decode(candidateData, label: "candidate Package.resolved")
        try candidateProjectRequire(publicLock.version == 3 && candidateLock.version == 3,
                                    "Package.resolved must use schema version 3.")
        try candidateProjectRequire(ElementCallCandidateRequest.isLowercaseHex(publicLock.originHash, count: 64) &&
            ElementCallCandidateRequest.isLowercaseHex(candidateLock.originHash, count: 64),
            "Package.resolved origin hashes must be valid.")

        try candidateProjectRequire(publicLock.pins.allSatisfy { try identity(of: $0) != elementCallIdentity },
                                    "The release Package.resolved still contains the obsolete remote Element Call pin.")
        try candidateProjectRequire(candidateLock.pins.allSatisfy { try identity(of: $0) != elementCallIdentity },
                                    "The transient Package.resolved still contains the remote Element Call pin.")
        try candidateProjectRequire(canonicalJSON(publicLock.pins) == canonicalJSON(candidateLock.pins),
                                    "The transient Package.resolved changed a dependency other than Element Call.")
    }

    private static func decode(_ data: Data, label: String) throws -> (originHash: String, pins: [[String: Any]], version: Int64) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["originHash", "pins", "version"],
              let originHash = root["originHash"] as? String,
              let pins = root["pins"] as? [[String: Any]] else {
            throw ElementCallCandidateError.validation("The \(label) structure is invalid.")
        }
        let version = try ElementCallCandidateJSON.safeInteger(root["version"], label: "Package.resolved version")
        var identities = Set<String>()
        for pin in pins {
            let pinIdentity = try identity(of: pin)
            try candidateProjectRequire(identities.insert(pinIdentity).inserted,
                                        "The \(label) contains a duplicate package identity.")
        }
        return (originHash, pins, version)
    }

    private static func identity(of pin: [String: Any]) throws -> String {
        guard let identity = pin["identity"] as? String, !identity.isEmpty else {
            throw ElementCallCandidateError.validation("Package.resolved contains an invalid package identity.")
        }
        return identity
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

enum ElementCallCandidateDeviceRequest {
    static func resolve(deviceUDID: String?, candidateRequested: Bool) throws -> String? {
        guard let deviceUDID else { return nil }
        try candidateProjectRequire(candidateRequested,
                                    "A device UDID may only be used with a complete Element Call candidate request.")
        let bytes = deviceUDID.utf8
        let modernComponents = deviceUDID.split(separator: "-", omittingEmptySubsequences: false)
        let isModern = modernComponents.count == 2 && modernComponents[0].utf8.count == 8 &&
            modernComponents[1].utf8.count == 16 && modernComponents.allSatisfy { $0.utf8.allSatisfy(isHex) }
        let isLegacy = bytes.count == 40 && bytes.allSatisfy(isHex)
        try candidateProjectRequire(isModern || isLegacy,
                                    "The development device UDID must use an Apple hardware UDID format.")
        return deviceUDID
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

struct ElementCallCandidateArchiveRequest {
    let archiveURL: URL
    let exportURL: URL?
    let exportOptionsURL: URL?

    static func resolve(archivePath: String?,
                        exportPath: String?,
                        exportOptionsPlist: String?,
                        deviceRequested: Bool,
                        candidateRequested: Bool) throws -> Self? {
        guard archivePath != nil || exportPath != nil || exportOptionsPlist != nil else {
            return nil
        }
        try candidateProjectRequire(candidateRequested,
                                    "A distribution archive may only be used with a complete Element Call candidate request.")
        try candidateProjectRequire(!deviceRequested,
                                    "A distribution archive cannot be combined with a development device install.")
        guard let archivePath else {
            throw ElementCallCandidateError.validation("A distribution archive requires --archive-path.")
        }

        let archiveURL = try outputURL(path: archivePath,
                                       label: "candidate distribution archive path",
                                       expectedExtension: "xcarchive")
        try candidateProjectRequire((exportPath == nil) == (exportOptionsPlist == nil),
                                    "--export-path and --export-options-plist must be provided together.")
        let exportURL = try exportPath.map {
            try outputURL(path: $0,
                          label: "candidate distribution export path",
                          expectedExtension: nil)
        }
        let exportOptionsURL = try exportOptionsPlist.map {
            try ElementCallCandidatePath.validateExisting(URL(filePath: $0),
                                                          kind: .file,
                                                          label: "candidate export options plist")
        }
        return Self(archiveURL: archiveURL,
                    exportURL: exportURL,
                    exportOptionsURL: exportOptionsURL)
    }

    private static func outputURL(path: String,
                                  label: String,
                                  expectedExtension: String?) throws -> URL {
        try ElementCallCandidatePath.validateRecordedAbsolute(path, label: label)
        let url = URL(filePath: path)
        if let expectedExtension {
            try candidateProjectRequire(url.pathExtension == expectedExtension,
                                        "\(label) must use .\(expectedExtension).")
        }
        _ = try ElementCallCandidatePath.validateExisting(url.deletingLastPathComponent(),
                                                          kind: .directory,
                                                          label: "\(label) parent")
        try candidateProjectRequire(!FileManager.default.fileExists(atPath: url.path),
                                    "\(label) must not already exist.")
        return url
    }
}

enum ElementCallCandidateBuildInvocation {
    static func resolveArguments(projectURL: URL,
                                 derivedDataURL: URL,
                                 sourcePackagesURL: URL) -> [String] {
        let temporaryRootURL = derivedDataURL.deletingLastPathComponent()
        return [
            "-IDEPackageSupportDisableManifestSandbox=1",
            "-project", projectURL.path,
            "-scheme", "ElementX",
            "-derivedDataPath", derivedDataURL.path,
            "-resultBundlePath", temporaryRootURL.appending(path: "Resolve.xcresult").path,
            "-clonedSourcePackagesDirPath", sourcePackagesURL.path,
            "-skipPackageUpdates",
            "-resolvePackageDependencies"
        ]
    }

    static func arguments(projectURL: URL,
                          derivedDataURL: URL,
                          sourcePackagesURL: URL,
                          repositoryURL: URL,
                          deviceUDID: String? = nil) -> [String] {
        let temporaryRootURL = derivedDataURL.deletingLastPathComponent()
        let platformArguments: [String] = if deviceUDID == nil {
            ["-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator"]
        } else {
            ["-sdk", "iphoneos", "-destination", "generic/platform=iOS"]
        }
        let signingArguments: [String] = if deviceUDID == nil {
            ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]
        } else {
            []
        }
        var arguments = [
            "-IDEPackageSupportDisableManifestSandbox=1",
            "-project", projectURL.path,
            "-scheme", "ElementX",
            "-configuration", "Debug"
        ]
        arguments += platformArguments
        arguments += [
            "-derivedDataPath", derivedDataURL.path,
            "-resultBundlePath", temporaryRootURL.appending(path: "Build.xcresult").path,
            "-clonedSourcePackagesDirPath", sourcePackagesURL.path,
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile"
        ]
        arguments += signingArguments
        arguments += [
            "OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox",
            "SRCROOT=\(repositoryURL.path)",
            "build"
        ]
        return arguments
    }

    static func archiveArguments(projectURL: URL,
                                 derivedDataURL: URL,
                                 sourcePackagesURL: URL,
                                 repositoryURL: URL,
                                 archiveURL: URL) -> [String] {
        let temporaryRootURL = derivedDataURL.deletingLastPathComponent()
        return [
            "-IDEPackageSupportDisableManifestSandbox=1",
            "-project", projectURL.path,
            "-scheme", "ElementX",
            "-configuration", "Release",
            "-sdk", "iphoneos",
            "-destination", "generic/platform=iOS",
            "-archivePath", archiveURL.path,
            "-derivedDataPath", derivedDataURL.path,
            "-resultBundlePath", temporaryRootURL.appending(path: "Archive.xcresult").path,
            "-clonedSourcePackagesDirPath", sourcePackagesURL.path,
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
            "OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox",
            "SRCROOT=\(repositoryURL.path)",
            "archive"
        ]
    }

    static func exportArguments(archiveURL: URL,
                                exportURL: URL,
                                exportOptionsURL: URL) -> [String] {
        [
            "-exportArchive",
            "-archivePath", archiveURL.path,
            "-exportPath", exportURL.path,
            "-exportOptionsPlist", exportOptionsURL.path
        ]
    }

    static func environment(repositoryURL: URL,
                            gitDirectoryURL: URL,
                            gitCommonDirectoryURL: URL,
                            temporaryRootURL: URL,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["JUNCHAT_XCODEBUILD_READ_ONLY_ROOT"] = repositoryURL.path
        environment["JUNCHAT_XCODEBUILD_READ_ONLY_GIT_DIR"] = gitDirectoryURL.path
        environment["JUNCHAT_XCODEBUILD_READ_ONLY_GIT_COMMON_DIR"] = gitCommonDirectoryURL.path
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["XBS_DISABLE_SANDBOXED_BUILDS"] = "YES"
        environment["TMPDIR"] = temporaryRootURL.path + "/"
        return environment
    }
}

enum ElementCallCandidateDeviceInstallation {
    private struct BundleArtifact {
        let url: URL
        let bundleIdentifier: String
        let packageType: String
    }

    static func appURL(derivedDataURL: URL) -> URL {
        derivedDataURL.appending(path: "Build/Products/Debug-iphoneos/Junchat.app")
    }

    static func arguments(deviceUDID: String, appURL: URL) -> [String] {
        ["devicectl", "device", "install", "app", "--device", deviceUDID, appURL.path]
    }

    static func validateProfile(_ data: Data,
                                bundleIdentifier: String,
                                teamIdentifier: String,
                                deviceUDID: String,
                                now: Date = Date()) throws {
        guard let profile = try PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil) as? [String: Any],
            profile["TeamIdentifier"] as? [String] == [teamIdentifier],
            let expirationDate = profile["ExpirationDate"] as? Date,
            expirationDate > now,
            let provisionedDevices = profile["ProvisionedDevices"] as? [String],
            provisionedDevices.contains(deviceUDID),
            let entitlements = profile["Entitlements"] as? [String: Any],
            entitlements["application-identifier"] as? String == "\(teamIdentifier).\(bundleIdentifier)",
            entitlements["com.apple.developer.team-identifier"] as? String == teamIdentifier,
            entitlements["get-task-allow"] as? Bool == true else {
            throw ElementCallCandidateError.validation("The signed candidate does not use the expected development profile for \(bundleIdentifier) and device \(deviceUDID).")
        }
    }

    static func validateAndInstall(appURL: URL,
                                   deviceUDID: String,
                                   repositoryURL: URL) throws {
        _ = try ElementCallCandidatePath.validateExisting(appURL, kind: .directory,
                                                          label: "development-signed candidate app")
        let metadata = try JunchatReleaseArtifacts.ExpectedMetadata.current(projectDirectory: repositoryURL)
        let artifacts = [
            BundleArtifact(url: appURL,
                           bundleIdentifier: metadata.bundleIdentifier,
                           packageType: "APPL"),
            BundleArtifact(url: appURL.appending(path: "PlugIns/NSE.appex"),
                           bundleIdentifier: "\(metadata.bundleIdentifier).nse",
                           packageType: "XPC!"),
            BundleArtifact(url: appURL.appending(path: "PlugIns/ShareExtension.appex"),
                           bundleIdentifier: "\(metadata.bundleIdentifier).shareextension",
                           packageType: "XPC!")
        ]
        for artifact in artifacts {
            _ = try ElementCallCandidatePath.validateExisting(artifact.url, kind: .directory,
                                                              label: "signed candidate bundle")
            let infoURL = artifact.url.appending(path: "Info.plist")
            let profileURL = artifact.url.appending(path: "embedded.mobileprovision")
            _ = try ElementCallCandidatePath.validateExisting(infoURL, kind: .file,
                                                              label: "signed candidate Info.plist")
            _ = try ElementCallCandidatePath.validateExisting(profileURL, kind: .file,
                                                              label: "signed candidate provisioning profile")
            guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL),
                                                                        options: [],
                                                                        format: nil) as? [String: Any],
                info["CFBundleIdentifier"] as? String == artifact.bundleIdentifier,
                info["CFBundlePackageType"] as? String == artifact.packageType,
                info["CFBundleShortVersionString"] as? String == metadata.version,
                info["CFBundleVersion"] as? String == metadata.build else {
                throw ElementCallCandidateError.validation("The signed candidate bundle metadata is invalid: \(artifact.bundleIdentifier).")
            }
            let profileData = try CandidateProcess.capture(executable: "/usr/bin/security",
                                                           arguments: ["cms", "-D", "-i", profileURL.path],
                                                           currentDirectory: appURL)
            try validateProfile(profileData,
                                bundleIdentifier: artifact.bundleIdentifier,
                                teamIdentifier: metadata.developmentTeam,
                                deviceUDID: deviceUDID)
        }
        try CandidateProcess.run(executable: "/usr/bin/codesign",
                                 arguments: ["--verify", "--deep", "--strict", appURL.path],
                                 currentDirectory: appURL)
        try CandidateProcess.run(executable: "/usr/bin/xcrun",
                                 arguments: arguments(deviceUDID: deviceUDID, appURL: appURL),
                                 currentDirectory: appURL)
    }
}

struct BuildElementCallCandidate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build-element-call-candidate",
                                                    abstract: "Builds a verified local Element Call candidate for simulator or an explicitly selected development device.")

    @Option(name: .customLong("manifest-path"), help: "Canonical absolute path to the schema-v4 manifest.")
    var manifestPath: String?

    @Option(name: .customLong("manifest-sha256"), help: "Expected lowercase SHA-256 of the exact manifest bytes.")
    var manifestSHA256: String?

    @Option(name: .customLong("source-commit"), help: "Expected lowercase 40-character Element Call source commit.")
    var sourceCommit: String?

    @Option(name: .customLong("source-packages-path"), help: "Complete local SourcePackages seed for offline resolution.")
    var sourcePackagesPath: String?

    @Option(name: .customLong("device-udid"), help: "Explicit hardware UDID for a development-signed Debug install.")
    var deviceUDID: String?

    @Option(name: .customLong("archive-path"), help: "Canonical absolute output path for a distribution archive.")
    var archivePath: String?

    @Option(name: .customLong("export-path"), help: "Canonical absolute output directory for an exported archive.")
    var exportPath: String?

    @Option(name: .customLong("export-options-plist"), help: "Canonical absolute path to export options for archive export.")
    var exportOptionsPlist: String?

    func run() throws {
        let repositoryURL = URL.projectDirectory.standardizedFileURL
        let request = try ElementCallCandidateRequest.resolve(manifestPath: manifestPath,
                                                              manifestSHA256: manifestSHA256,
                                                              sourceCommit: sourceCommit)
        let resolvedDeviceUDID = try ElementCallCandidateDeviceRequest.resolve(deviceUDID: deviceUDID,
                                                                               candidateRequested: request != nil)
        let archiveRequest = try ElementCallCandidateArchiveRequest.resolve(archivePath: archivePath,
                                                                            exportPath: exportPath,
                                                                            exportOptionsPlist: exportOptionsPlist,
                                                                            deviceRequested: resolvedDeviceUDID != nil,
                                                                            candidateRequested: request != nil)
        let sourcePackagesSeedURL = try ElementCallCandidateSourcePackages.resolve(path: sourcePackagesPath,
                                                                                   candidateRequested: request != nil)
        guard let request, let sourcePackagesSeedURL else {
            let projectYAMLURL = repositoryURL.appending(path: "project.yml")
            let defaultProjectYAML = try String(contentsOf: projectYAMLURL, encoding: .utf8)
            try ElementCallCandidateProjectSpec.validateDefault(defaultProjectYAML)
            let releaseSource = try ElementCallReleaseSource.validate(repositoryURL: repositoryURL)
            let resolutionURL = repositoryURL.appending(path: TrackedProjectState.packageResolutionPath)
            try ElementCallCandidatePackageResolution.validateRelease(Data(contentsOf: resolutionURL))
            logger.info("No Element Call candidate requested; using release-locked \(releaseSource.version) at \(releaseSource.sourceCommit).")
            return
        }

        let protectedState = try ProtectedRepositoryState.capture(repositoryURL: repositoryURL)
        let trackedState = try TrackedProjectState.capture(repositoryURL: repositoryURL)
        let defaultProjectYAML = try trackedState.projectYAML()
        try ElementCallCandidateProjectSpec.validateDefault(defaultProjectYAML)
        _ = try ElementCallReleaseSource.validate(repositoryURL: repositoryURL)
        try trackedState.validateUnchanged()
        let package = try ElementCallCandidateManifest.verify(request)
        let temporaryParent = try ElementCallCandidatePath.systemTemporaryDirectory()
        let staged = try ElementCallCandidateStaging.stage(package, under: temporaryParent)
        var operationError: Error?
        do {
            let specYAML = try ElementCallCandidateProjectSpec.make(defaultProjectYAML: defaultProjectYAML,
                                                                    stagedPackageURL: staged.packageURL,
                                                                    repositoryURL: repositoryURL,
                                                                    developmentSigning: resolvedDeviceUDID != nil)
            let specURL = staged.rootURL.appending(path: "candidate-project.yml")
            try writePrivate(specYAML.data(using: .utf8)!, to: specURL)
            try validatePackageIdentity(packageURL: staged.packageURL,
                                        protectedState: protectedState,
                                        temporaryRoot: staged.rootURL)
            let generatedProjectURL = try generateProject(specURL: specURL,
                                                          protectedState: protectedState,
                                                          temporaryRoot: staged.rootURL)
            let packageResolution = try seedTransientPackageResolution(generatedProjectURL: generatedProjectURL,
                                                                       publicData: trackedState.packageResolutionData())
            let sourcePackagesURL = try ElementCallCandidateSourcePackages.stage(from: sourcePackagesSeedURL,
                                                                                 publicResolutionData: packageResolution.publicData,
                                                                                 under: staged.rootURL)
            let derivedDataURL = staged.rootURL.appending(path: "DerivedData")
            try resolvePackages(projectURL: generatedProjectURL,
                                derivedDataURL: derivedDataURL,
                                sourcePackagesURL: sourcePackagesURL,
                                protectedState: protectedState)
            let candidateResolution = try Data(contentsOf: packageResolution.destinationURL)
            try ElementCallCandidatePackageResolution.validate(publicData: packageResolution.publicData,
                                                               candidateData: candidateResolution)
            try trackedState.validateUnchanged()
            if let archiveRequest {
                try archive(projectURL: generatedProjectURL,
                            derivedDataURL: derivedDataURL,
                            sourcePackagesURL: sourcePackagesURL,
                            archiveRequest: archiveRequest,
                            protectedState: protectedState)
            } else {
                try build(projectURL: generatedProjectURL,
                          derivedDataURL: derivedDataURL,
                          sourcePackagesURL: sourcePackagesURL,
                          deviceUDID: resolvedDeviceUDID,
                          protectedState: protectedState)
            }
            try trackedState.validateUnchanged()
            if let resolvedDeviceUDID {
                try ElementCallCandidateDeviceInstallation.validateAndInstall(appURL: ElementCallCandidateDeviceInstallation.appURL(derivedDataURL: derivedDataURL),
                                                                              deviceUDID: resolvedDeviceUDID,
                                                                              repositoryURL: repositoryURL)
                try trackedState.validateUnchanged()
            }
        } catch {
            operationError = error
        }
        do {
            try trackedState.validateUnchanged()
        } catch {
            operationError = error
        }
        do {
            try FileManager.default.removeItem(at: staged.rootURL)
        } catch {
            let primary = operationError.map { " Primary failure: \($0.localizedDescription)" } ?? ""
            throw ElementCallCandidateError.validation("Unable to remove candidate staging root \(staged.rootURL.path).\(primary)")
        }
        if let operationError {
            throw operationError
        }
        if let resolvedDeviceUDID {
            logger.info("Installed Element Call candidate \(package.version) as an ephemeral development-signed Debug build on \(resolvedDeviceUDID).")
        } else if let archiveRequest {
            let exportSuffix = archiveRequest.exportURL.map { " and exported it to \($0.path)" } ?? ""
            logger.info("Archived Element Call candidate \(package.version) to \(archiveRequest.archiveURL.path)\(exportSuffix).")
        } else {
            logger.info("Verified Element Call candidate \(package.version) with an unsigned Debug simulator build.")
        }
    }

    private func validatePackageIdentity(packageURL: URL,
                                         protectedState: ProtectedRepositoryState,
                                         temporaryRoot: URL) throws {
        let output = try CandidateProcess.capture(executable: "/usr/bin/sandbox-exec",
                                                  arguments: ["-p", readOnlyNetworkSandbox(protectedState: protectedState),
                                                              "/usr/bin/xcrun", "swift", "package", "--package-path", packageURL.path,
                                                              "--disable-sandbox", "dump-package"],
                                                  currentDirectory: temporaryRoot)
        try ElementCallCandidatePackageIdentity.validate(dumpPackageJSON: output)
    }

    private func generateProject(specURL: URL,
                                 protectedState: ProtectedRepositoryState,
                                 temporaryRoot: URL) throws -> URL {
        try CandidateProcess.run(executable: "/usr/bin/sandbox-exec",
                                 arguments: ["-p", readOnlyNetworkSandbox(protectedState: protectedState),
                                             "/opt/homebrew/bin/xcodegen", "generate", "--no-env",
                                             "--spec", specURL.path, "--project", temporaryRoot.path,
                                             "--project-root", protectedState.repositoryURL.path],
                                 currentDirectory: protectedState.repositoryURL)
        let projectURL = temporaryRoot.appending(path: "ElementX.xcodeproj")
        _ = try ElementCallCandidatePath.validateExisting(projectURL, kind: .directory, label: "transient ElementX project")
        return projectURL
    }

    private func seedTransientPackageResolution(generatedProjectURL: URL,
                                                publicData: Data) throws -> (destinationURL: URL, publicData: Data) {
        let destinationDirectory = generatedProjectURL.appending(path: "project.xcworkspace/xcshareddata/swiftpm")
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = destinationDirectory.appending(path: "Package.resolved")
        try writePrivate(publicData, to: destination)
        return (destination, publicData)
    }

    private func resolvePackages(projectURL: URL,
                                 derivedDataURL: URL,
                                 sourcePackagesURL: URL,
                                 protectedState: ProtectedRepositoryState) throws {
        try runXcodebuild(arguments: ElementCallCandidateBuildInvocation.resolveArguments(projectURL: projectURL,
                                                                                          derivedDataURL: derivedDataURL,
                                                                                          sourcePackagesURL: sourcePackagesURL),
                          derivedDataURL: derivedDataURL,
                          protectedState: protectedState)
    }

    private func build(projectURL: URL,
                       derivedDataURL: URL,
                       sourcePackagesURL: URL,
                       deviceUDID: String?,
                       protectedState: ProtectedRepositoryState) throws {
        try runXcodebuild(arguments: ElementCallCandidateBuildInvocation.arguments(projectURL: projectURL,
                                                                                   derivedDataURL: derivedDataURL,
                                                                                   sourcePackagesURL: sourcePackagesURL,
                                                                                   repositoryURL: protectedState.repositoryURL,
                                                                                   deviceUDID: deviceUDID),
                          derivedDataURL: derivedDataURL,
                          protectedState: protectedState)
    }

    private func archive(projectURL: URL,
                         derivedDataURL: URL,
                         sourcePackagesURL: URL,
                         archiveRequest: ElementCallCandidateArchiveRequest,
                         protectedState: ProtectedRepositoryState) throws {
        try runXcodebuild(arguments: ElementCallCandidateBuildInvocation.archiveArguments(projectURL: projectURL,
                                                                                          derivedDataURL: derivedDataURL,
                                                                                          sourcePackagesURL: sourcePackagesURL,
                                                                                          repositoryURL: protectedState.repositoryURL,
                                                                                          archiveURL: archiveRequest.archiveURL),
                          derivedDataURL: derivedDataURL,
                          protectedState: protectedState)
        if let exportURL = archiveRequest.exportURL,
           let exportOptionsURL = archiveRequest.exportOptionsURL {
            try runXcodebuild(arguments: ElementCallCandidateBuildInvocation.exportArguments(archiveURL: archiveRequest.archiveURL,
                                                                                             exportURL: exportURL,
                                                                                             exportOptionsURL: exportOptionsURL),
                              derivedDataURL: derivedDataURL,
                              protectedState: protectedState)
        }
    }

    private func runXcodebuild(arguments: [String],
                               derivedDataURL: URL,
                               protectedState: ProtectedRepositoryState) throws {
        let wrapperURL = protectedState.repositoryURL.appending(path: "Tools/Scripts/run_xcodebuild.sh")
        _ = try ElementCallCandidatePath.validateExisting(wrapperURL, kind: .file, label: "Xcode build wrapper")
        let environment = ElementCallCandidateBuildInvocation.environment(repositoryURL: protectedState.repositoryURL,
                                                                          gitDirectoryURL: protectedState.gitDirectoryURL,
                                                                          gitCommonDirectoryURL: protectedState.gitCommonDirectoryURL,
                                                                          temporaryRootURL: derivedDataURL.deletingLastPathComponent())
        try CandidateProcess.run(executable: wrapperURL.path,
                                 arguments: arguments,
                                 currentDirectory: protectedState.repositoryURL,
                                 environment: environment)
    }

    private func readOnlyNetworkSandbox(protectedState: ProtectedRepositoryState) throws -> String {
        let roots = [protectedState.repositoryURL, protectedState.gitDirectoryURL, protectedState.gitCommonDirectoryURL]
        let rules = try roots.map { url -> String in
            let path = url.path
            try candidateProjectRequire(path.unicodeScalars.allSatisfy { $0.value >= 0x20 } &&
                !path.contains("\"") && !path.contains("\\"),
                "A protected repository path cannot be represented safely in the sandbox profile.")
            return #"(deny file-write* (subpath "\#(path)"))"#
        }
        return "(version 1) (allow default) (deny network*) \(rules.joined(separator: " "))"
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try candidateProjectRequire(descriptor >= 0, "Unable to create a private transient file.")
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                try candidateProjectRequire(count > 0, "Unable to write the transient XcodeGen spec.")
                offset += count
            }
        }
        try candidateProjectRequire(fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0,
                                    "Unable to secure the private transient file.")
    }
}

struct ProtectedRepositoryState {
    let repositoryURL: URL
    let gitDirectoryURL: URL
    let gitCommonDirectoryURL: URL

    static func capture(repositoryURL: URL) throws -> Self {
        let output = try CandidateProcess.capture(executable: "/usr/bin/git",
                                                  arguments: ["-C", repositoryURL.path, "rev-parse", "--path-format=absolute",
                                                              "--git-dir", "--git-common-dir"],
                                                  currentDirectory: repositoryURL)
        guard let value = String(data: output, encoding: .utf8) else {
            throw ElementCallCandidateError.validation("Git returned non-UTF-8 repository paths.")
        }
        let paths = value.split(whereSeparator: { $0.isNewline }).map(String.init)
        try candidateProjectRequire(paths.count == 2, "Unable to resolve the worktree and common Git directories.")
        let gitDirectoryURL = URL(filePath: paths[0]).standardizedFileURL
        let gitCommonDirectoryURL = URL(filePath: paths[1]).standardizedFileURL
        _ = try ElementCallCandidatePath.validateExisting(gitDirectoryURL, kind: .directory, label: "worktree Git directory")
        _ = try ElementCallCandidatePath.validateExisting(gitCommonDirectoryURL, kind: .directory, label: "common Git directory")
        return Self(repositoryURL: repositoryURL,
                    gitDirectoryURL: gitDirectoryURL,
                    gitCommonDirectoryURL: gitCommonDirectoryURL)
    }
}

struct TrackedProjectState {
    struct FileSnapshot {
        let relativePath: String
        let url: URL
        let data: Data
    }

    static let packageResolutionPath = "ElementX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

    let repositoryURL: URL
    let files: [FileSnapshot]
    let head: Data
    let status: Data

    static func capture(repositoryURL: URL) throws -> Self {
        let paths = [
            "project.yml", "app.yml", "ElementX.xcodeproj/project.pbxproj",
            packageResolutionPath
        ]
        let files = try paths.map { path in
            let url = repositoryURL.appending(path: path)
            return try FileSnapshot(relativePath: path, url: url, data: Data(contentsOf: url))
        }
        let head = try git(repositoryURL: repositoryURL, arguments: ["rev-parse", "HEAD"])
        let status = try git(repositoryURL: repositoryURL,
                             arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        return Self(repositoryURL: repositoryURL, files: files, head: head, status: status)
    }

    func projectYAML() throws -> String {
        guard let data = files.first(where: { $0.relativePath == "project.yml" })?.data,
              let yaml = String(data: data, encoding: .utf8) else {
            throw ElementCallCandidateError.validation("The captured project.yml is missing or is not UTF-8.")
        }
        return yaml
    }

    func packageResolutionData() throws -> Data {
        guard let data = files.first(where: { $0.relativePath == Self.packageResolutionPath })?.data else {
            throw ElementCallCandidateError.validation("The captured Package.resolved is missing.")
        }
        return data
    }

    func validateUnchanged() throws {
        for file in files {
            try candidateProjectRequire(Data(contentsOf: file.url) == file.data,
                                        "Candidate tooling modified persistent project state: \(file.url.path).")
        }
        try candidateProjectRequire(Self.git(repositoryURL: repositoryURL, arguments: ["rev-parse", "HEAD"]) == head &&
            Self.git(repositoryURL: repositoryURL,
                     arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) == status,
            "Candidate tooling modified the repository or Git state.")
    }

    private static func git(repositoryURL: URL, arguments: [String]) throws -> Data {
        try CandidateProcess.capture(executable: "/usr/bin/git",
                                     arguments: ["--no-optional-locks", "-C", repositoryURL.path] + arguments,
                                     currentDirectory: repositoryURL)
    }
}

private enum CandidateProcess {
    static func capture(executable: String, arguments: [String], currentDirectory: URL) throws -> Data {
        let pipe = Pipe()
        let process = configured(executable: executable, arguments: arguments, currentDirectory: currentDirectory,
                                 environment: ProcessInfo.processInfo.environment)
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try candidateProjectRequire(process.terminationReason == .exit && process.terminationStatus == 0,
                                    "Candidate subprocess failed: \(executable).")
        return data
    }

    static func run(executable: String,
                    arguments: [String],
                    currentDirectory: URL,
                    environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let process = configured(executable: executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        try candidateProjectRequire(process.terminationReason == .exit && process.terminationStatus == 0,
                                    "Candidate subprocess failed: \(executable).")
    }

    private static func configured(executable: String,
                                   arguments: [String],
                                   currentDirectory: URL,
                                   environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        return process
    }
}

private func candidateProjectRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ElementCallCandidateError.validation(message) }
}
