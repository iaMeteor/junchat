import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import Subprocess
import System
import Yams

struct ReleaseArtifactCommandRunner {
    struct Output {
        let standardOutput: String
        let standardError: String
    }

    let codesignExecutablePath: String
    let otoolExecutablePath: String
    let dwarfdumpExecutablePath: String
    let run: @Sendable (_ executablePath: String, _ arguments: [String]) async throws -> Output

    static func production(codesignExecutablePath: String = "/usr/bin/codesign",
                           otoolExecutablePath: String = "/usr/bin/otool",
                           dwarfdumpExecutablePath: String = "/usr/bin/dwarfdump") -> Self {
        let executablePaths = [codesignExecutablePath, otoolExecutablePath, dwarfdumpExecutablePath]
        return Self(codesignExecutablePath: codesignExecutablePath,
                    otoolExecutablePath: otoolExecutablePath,
                    dwarfdumpExecutablePath: dwarfdumpExecutablePath) { executablePath, arguments in
            guard executablePaths.contains(executablePath),
                  NSString(string: executablePath).isAbsolutePath else {
                throw ValidationError("Release artifact validation requires an absolute allowlisted tool path.")
            }
            let result = try await CI.run(.path(FilePath(executablePath)),
                                          Arguments(arguments),
                                          output: .string(limit: 1_048_576),
                                          error: .string(limit: 1_048_576))
            return Output(standardOutput: result.standardOutput ?? "",
                          standardError: result.standardError ?? "")
        }
    }
}

enum JunchatReleaseArtifacts {
    struct Validation {
        let artifacts: JunchatReleasePreflight.ReleaseArtifacts
        let bindingDigest: String?
    }

    struct ExpectedMetadata: Codable, Equatable {
        let bundleIdentifier: String
        let developmentTeam: String
        let version: String
        let build: String

        static func current(projectDirectory: URL = .projectDirectory) throws -> Self {
            let projectYAML = try String(contentsOf: projectDirectory.appending(path: "project.yml"),
                                         encoding: .utf8)
            let appYAML = try String(contentsOf: projectDirectory.appending(path: "app.yml"),
                                     encoding: .utf8)
            let version = try JunchatReleaseVersion.parse(projectYAML)
            guard let root = try Yams.load(yaml: appYAML) as? [String: Any],
                  let settings = root["settings"] as? [String: Any],
                  let bundleIdentifier = settings["BASE_BUNDLE_IDENTIFIER"] as? String,
                  !bundleIdentifier.isEmpty,
                  let developmentTeam = settings["DEVELOPMENT_TEAM"] as? String,
                  !developmentTeam.isEmpty else {
                throw ValidationError("app.yml does not contain exact Junchat release identity metadata.")
            }
            return Self(bundleIdentifier: bundleIdentifier,
                        developmentTeam: developmentTeam,
                        version: version.name,
                        build: String(version.build))
        }
    }

    static func validate(environment: [String: String],
                         fileManager: FileManager = .default,
                         commandRunner: ReleaseArtifactCommandRunner = .production(),
                         artifactBindingURL: URL? = nil) async throws -> Validation {
        let expectedMetadata = try ExpectedMetadata.current()
        let locations = try artifactLocations(environment: environment, fileManager: fileManager)
        let before = try captureBinding(locations: locations,
                                        expectedMetadata: expectedMetadata,
                                        fileManager: fileManager)

        try validatePropertyLists(locations: locations,
                                  expectedMetadata: expectedMetadata,
                                  fileManager: fileManager)
        try await validateSignedMachOAndDSYM(locations: locations,
                                             expectedMetadata: expectedMetadata,
                                             commandRunner: commandRunner)

        let after = try captureBinding(locations: locations,
                                       expectedMetadata: expectedMetadata,
                                       fileManager: fileManager)
        guard before == after else {
            throw ValidationError("Release artifacts changed while they were being validated.")
        }

        let digest = try artifactBindingURL.map {
            try writeBinding(after, to: $0, fileManager: fileManager)
        }
        return Validation(artifacts: locations.artifacts,
                          bindingDigest: digest)
    }

    static func revalidateBinding(atPath bindingPath: String,
                                  expectedDigest: String,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  fileManager: FileManager = .default,
                                  validateProjectMetadata: Bool = false) throws -> JunchatReleasePreflight.ReleaseArtifacts {
        guard isSHA256(expectedDigest) else {
            throw ValidationError("The expected release artifact binding digest is invalid.")
        }
        let bindingURL = try canonicalBindingURL(path: bindingPath,
                                                 fileManager: fileManager,
                                                 requireExistingFile: true)
        let attributesBefore = try privateBindingAttributes(at: bindingURL, fileManager: fileManager)
        let data = try Data(contentsOf: bindingURL, options: .mappedIfSafe)
        let attributesAfter = try privateBindingAttributes(at: bindingURL, fileManager: fileManager)
        guard attributesBefore == attributesAfter,
              sha256(data) == expectedDigest else {
            throw ValidationError("The release artifact binding changed or does not match its expected digest.")
        }

        let decoder = JSONDecoder()
        let expectedBinding: ReleaseArtifactBinding
        do {
            expectedBinding = try decoder.decode(ReleaseArtifactBinding.self, from: data)
        } catch {
            throw ValidationError("The release artifact binding is malformed.")
        }
        guard expectedBinding.schemaVersion == ReleaseArtifactBinding.currentSchemaVersion else {
            throw ValidationError("The release artifact binding schema is unsupported.")
        }
        if validateProjectMetadata {
            guard try ExpectedMetadata.current() == expectedBinding.expectedMetadata else {
                throw ValidationError("The project release metadata changed after artifact preflight.")
            }
        }

        let locations = try artifactLocations(environment: environment, fileManager: fileManager)
        guard locations.archiveURL.path == expectedBinding.archiveRoot.path,
              locations.appURL.path == expectedBinding.appTree.root.path,
              locations.dSYMsURL.path == expectedBinding.dSYMsTree.root.path else {
            throw ValidationError("Release artifact paths changed after artifact preflight.")
        }
        let actualBinding = try captureBinding(locations: locations,
                                               expectedMetadata: expectedBinding.expectedMetadata,
                                               fileManager: fileManager)
        guard actualBinding == expectedBinding else {
            throw ValidationError("Release artifact identity or contents changed after artifact preflight.")
        }
        return locations.artifacts
    }

    // MARK: - Artifact validation

    private struct ArtifactLocations {
        let archiveURL: URL
        let archiveInfoURL: URL
        let appURL: URL
        let appInfoURL: URL
        let appExecutableURL: URL
        let dSYMsURL: URL
        let dSYMURL: URL
        let dSYMInfoURL: URL
        let dwarfURL: URL

        var artifacts: JunchatReleasePreflight.ReleaseArtifacts {
            .init(archiveURL: archiveURL,
                  signedAppURL: appURL,
                  dSYMsURL: dSYMsURL)
        }
    }

    private struct MachOSlice: Hashable {
        let architecture: String
        let uuid: UUID
    }

    private static func artifactLocations(environment: [String: String],
                                          fileManager: FileManager) throws -> ArtifactLocations {
        let archiveURL = try canonicalArtifactURL(variable: "CI_ARCHIVE_PATH",
                                                  environment: environment,
                                                  expectedExtension: "xcarchive")
        try requireDirectory(archiveURL, fileManager: fileManager)

        let appURL = archiveURL.appending(path: "Products/Applications/Junchat.app")
        let dSYMsURL = archiveURL.appending(path: "dSYMs")
        let dSYMURL = dSYMsURL.appending(path: "Junchat.app.dSYM")
        let locations = ArtifactLocations(archiveURL: archiveURL,
                                          archiveInfoURL: archiveURL.appending(path: "Info.plist"),
                                          appURL: appURL,
                                          appInfoURL: appURL.appending(path: "Info.plist"),
                                          appExecutableURL: appURL.appending(path: "Junchat"),
                                          dSYMsURL: dSYMsURL,
                                          dSYMURL: dSYMURL,
                                          dSYMInfoURL: dSYMURL.appending(path: "Contents/Info.plist"),
                                          dwarfURL: dSYMURL.appending(path: "Contents/Resources/DWARF/Junchat"))
        try requireDirectory(locations.appURL, fileManager: fileManager)
        try requireDirectory(locations.dSYMsURL, fileManager: fileManager)
        try requireDirectory(locations.dSYMURL, fileManager: fileManager)
        try requireRegularFile(locations.archiveInfoURL, fileManager: fileManager)
        try requireRegularFile(locations.appInfoURL, fileManager: fileManager)
        try requireRegularFile(locations.appExecutableURL, fileManager: fileManager)
        try requireRegularFile(locations.dSYMInfoURL, fileManager: fileManager)
        try requireRegularFile(locations.dwarfURL, fileManager: fileManager)

        let signedAppURL = try canonicalArtifactURL(variable: "CI_APP_STORE_SIGNED_APP_PATH",
                                                    environment: environment,
                                                    expectedExtension: "app")
        guard signedAppURL == appURL else {
            throw JunchatReleasePreflight.PreflightError.unexpectedSignedAppPath
        }
        return locations
    }

    private static func validatePropertyLists(locations: ArtifactLocations,
                                              expectedMetadata: ExpectedMetadata,
                                              fileManager: FileManager) throws {
        let archiveInfo = try propertyList(at: locations.archiveInfoURL, fileManager: fileManager)
        guard archiveInfo["ArchiveVersion"] as? Int == 2,
              archiveInfo["Name"] as? String == "Junchat",
              let applicationProperties = archiveInfo["ApplicationProperties"] as? [String: Any],
              applicationProperties["ApplicationPath"] as? String == "Applications/Junchat.app",
              applicationProperties["CFBundleIdentifier"] as? String == expectedMetadata.bundleIdentifier,
              applicationProperties["CFBundleShortVersionString"] as? String == expectedMetadata.version,
              applicationProperties["CFBundleVersion"] as? String == expectedMetadata.build else {
            throw JunchatReleasePreflight.PreflightError.invalidPropertyList(path: locations.archiveInfoURL.path)
        }

        let appInfo = try propertyList(at: locations.appInfoURL, fileManager: fileManager)
        guard appInfo["CFBundleExecutable"] as? String == "Junchat",
              appInfo["CFBundleIdentifier"] as? String == expectedMetadata.bundleIdentifier,
              appInfo["CFBundlePackageType"] as? String == "APPL",
              appInfo["CFBundleShortVersionString"] as? String == expectedMetadata.version,
              appInfo["CFBundleVersion"] as? String == expectedMetadata.build else {
            throw JunchatReleasePreflight.PreflightError.invalidPropertyList(path: locations.appInfoURL.path)
        }

        let dSYMInfo = try propertyList(at: locations.dSYMInfoURL, fileManager: fileManager)
        guard dSYMInfo["CFBundlePackageType"] as? String == "dSYM",
              dSYMInfo["CFBundleIdentifier"] as? String == "com.apple.xcode.dsym.\(expectedMetadata.bundleIdentifier)" else {
            throw JunchatReleasePreflight.PreflightError.invalidPropertyList(path: locations.dSYMInfoURL.path)
        }
    }

    private static func validateSignedMachOAndDSYM(locations: ArtifactLocations,
                                                   expectedMetadata: ExpectedMetadata,
                                                   commandRunner: ReleaseArtifactCommandRunner) async throws {
        _ = try await commandRunner.run(commandRunner.codesignExecutablePath, [
            "--verify", "--deep", "--strict", locations.appURL.path
        ])
        let signatureOutput = try await commandRunner.run(commandRunner.codesignExecutablePath, [
            "--display", "--verbose=4", locations.appURL.path
        ])
        let signatureMetadata = signatureOutput.standardOutput + "\n" + signatureOutput.standardError
        guard metadataValue(named: "Identifier", in: signatureMetadata) == expectedMetadata.bundleIdentifier,
              metadataValue(named: "TeamIdentifier", in: signatureMetadata) == expectedMetadata.developmentTeam,
              metadataValue(named: "Signature", in: signatureMetadata)?.lowercased() != "adhoc" else {
            throw ValidationError("The signed Junchat app has invalid code-signature identity metadata.")
        }

        let machHeader = try await commandRunner.run(commandRunner.otoolExecutablePath, ["-hv", locations.appExecutableURL.path])
        _ = try executeMachOSliceCount(machHeader.standardOutput + "\n" + machHeader.standardError)

        let appUUIDOutput = try await commandRunner.run(commandRunner.dwarfdumpExecutablePath, ["--uuid", locations.appExecutableURL.path])
        let dSYMUUIDOutput = try await commandRunner.run(commandRunner.dwarfdumpExecutablePath, ["--uuid", locations.dSYMURL.path])
        let appSlices = try machOSlices(fromDwarfdump: appUUIDOutput.standardOutput + "\n" + appUUIDOutput.standardError)
        let dSYMSlices = try machOSlices(fromDwarfdump: dSYMUUIDOutput.standardOutput + "\n" + dSYMUUIDOutput.standardError)
        guard appSlices == dSYMSlices else {
            throw ValidationError("The Junchat dSYM architecture and UUID set does not exactly match the app executable.")
        }
    }

    private static func metadataValue(named name: String, in output: String) -> String? {
        let prefix = "\(name)="
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix(prefix) else { return nil }
            return String(value.dropFirst(prefix.count))
        }
        guard values.count == 1, let value = values.first, !value.isEmpty, value != "not set" else {
            return nil
        }
        return value
    }

    private static func executeMachOSliceCount(_ output: String) throws -> Int {
        let lines = output.components(separatedBy: .newlines)
        var expectedFileTypeIndex: Int?
        var sliceCount = 0
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if let index = fields.firstIndex(of: "filetype"), fields.first == "magic" {
                expectedFileTypeIndex = index
                continue
            }
            guard let fileTypeIndex = expectedFileTypeIndex, !fields.isEmpty else { continue }
            guard fields.indices.contains(fileTypeIndex), fields[fileTypeIndex] == "EXECUTE" else {
                throw ValidationError("The Junchat app executable is not an EXECUTE Mach-O image.")
            }
            sliceCount += 1
            expectedFileTypeIndex = nil
        }
        guard sliceCount > 0, expectedFileTypeIndex == nil else {
            throw ValidationError("The Junchat app executable has malformed Mach-O headers.")
        }
        return sliceCount
    }

    private static func machOSlices(fromDwarfdump output: String) throws -> Set<MachOSlice> {
        var slices = Set<MachOSlice>()
        var parsedLineCount = 0
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("UUID: ") else { continue }
            let remainder = line.dropFirst("UUID: ".count)
            guard let architectureStart = remainder.firstIndex(of: "("),
                  let architectureEnd = remainder[architectureStart...].firstIndex(of: ")") else {
                throw ValidationError("dwarfdump returned malformed UUID output.")
            }
            let uuidValue = remainder[..<architectureStart].trimmingCharacters(in: .whitespaces)
            let architecture = remainder[remainder.index(after: architectureStart)..<architectureEnd]
            guard let uuid = UUID(uuidString: uuidValue),
                  !architecture.isEmpty,
                  architecture.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw ValidationError("dwarfdump returned malformed architecture or UUID metadata.")
            }
            parsedLineCount += 1
            slices.insert(MachOSlice(architecture: String(architecture), uuid: uuid))
        }
        guard !slices.isEmpty, slices.count == parsedLineCount,
              Set(slices.map(\.architecture)).count == slices.count else {
            throw ValidationError("dwarfdump did not return a unique nonempty architecture and UUID set.")
        }
        return slices
    }

    // MARK: - Binding

    private struct ReleaseArtifactBinding: Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let expectedMetadata: ExpectedMetadata
        let archiveRoot: RootIdentity
        let archiveInfo: InventoryEntry
        let appTree: BoundTree
        let dSYMsTree: BoundTree
    }

    private struct RootIdentity: Codable, Equatable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let permissions: UInt16
    }

    private struct BoundTree: Codable, Equatable {
        let root: RootIdentity
        let entries: [InventoryEntry]
    }

    private struct InventoryEntry: Codable, Equatable {
        enum Kind: String, Codable {
            case directory
            case file
            case symbolicLink
        }

        let path: String
        let kind: Kind
        let device: UInt64
        let inode: UInt64
        let permissions: UInt16
        let size: UInt64?
        let sha256: String?
        let symbolicLinkTarget: String?
    }

    private struct BindingFileAttributes: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let permissions: UInt16
    }

    private static func captureBinding(locations: ArtifactLocations,
                                       expectedMetadata: ExpectedMetadata,
                                       fileManager: FileManager) throws -> ReleaseArtifactBinding {
        try ReleaseArtifactBinding(schemaVersion: ReleaseArtifactBinding.currentSchemaVersion,
                                   expectedMetadata: expectedMetadata,
                                   archiveRoot: rootIdentity(at: locations.archiveURL, fileManager: fileManager),
                                   archiveInfo: inventoryEntry(at: locations.archiveInfoURL,
                                                               relativePath: "Info.plist",
                                                               treeRoot: locations.archiveURL,
                                                               fileManager: fileManager),
                                   appTree: boundTree(at: locations.appURL, fileManager: fileManager),
                                   dSYMsTree: boundTree(at: locations.dSYMsURL, fileManager: fileManager))
    }

    private static func boundTree(at rootURL: URL, fileManager: FileManager) throws -> BoundTree {
        let rootBefore = try rootIdentity(at: rootURL, fileManager: fileManager)
        var enumerationError: Swift.Error?
        guard let enumerator = fileManager.enumerator(at: rootURL,
                                                      includingPropertiesForKeys: nil,
                                                      options: [],
                                                      errorHandler: { _, error in
                                                          enumerationError = error
                                                          return false
                                                      }) else {
            throw ValidationError("Could not enumerate release artifact tree at \(rootURL.path).")
        }

        var urls = [URL]()
        for case let url as URL in enumerator {
            urls.append(url)
        }
        if let enumerationError { throw enumerationError }
        urls.sort { $0.path < $1.path }

        let rootPaths = try Set([rootURL.path, physicalPath(rootURL.path)])
        let entries = try urls.map { url -> InventoryEntry in
            guard let rootPrefix = rootPaths.map({ $0 + "/" }).first(where: { url.path.hasPrefix($0) }) else {
                throw ValidationError("A release artifact tree escaped its canonical root: \(url.path) is outside \(rootURL.path).")
            }
            let relativePath = String(url.path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else {
                throw ValidationError("A release artifact tree contains an invalid path.")
            }
            return try inventoryEntry(at: url,
                                      relativePath: relativePath,
                                      treeRoot: rootURL,
                                      fileManager: fileManager)
        }
        guard try rootIdentity(at: rootURL, fileManager: fileManager) == rootBefore else {
            throw ValidationError("A release artifact root changed during inventory.")
        }
        return BoundTree(root: rootBefore, entries: entries)
    }

    private static func inventoryEntry(at url: URL,
                                       relativePath: String,
                                       treeRoot: URL,
                                       fileManager: FileManager) throws -> InventoryEntry {
        let attributesBefore = try fileManager.attributesOfItem(atPath: url.path)
        let type = attributesBefore[.type] as? FileAttributeType
        let device = try unsignedAttribute(.systemNumber, in: attributesBefore, path: url.path)
        let inode = try unsignedAttribute(.systemFileNumber, in: attributesBefore, path: url.path)
        let permissions = try UInt16(truncatingIfNeeded: unsignedAttribute(.posixPermissions,
                                                                           in: attributesBefore,
                                                                           path: url.path))

        let entry: InventoryEntry
        switch type {
        case .typeDirectory:
            entry = InventoryEntry(path: relativePath,
                                   kind: .directory,
                                   device: device,
                                   inode: inode,
                                   permissions: permissions,
                                   size: nil,
                                   sha256: nil,
                                   symbolicLinkTarget: nil)
        case .typeRegular:
            let size = try unsignedAttribute(.size, in: attributesBefore, path: url.path)
            entry = try InventoryEntry(path: relativePath,
                                       kind: .file,
                                       device: device,
                                       inode: inode,
                                       permissions: permissions,
                                       size: size,
                                       sha256: sha256File(at: url),
                                       symbolicLinkTarget: nil)
        case .typeSymbolicLink:
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            let resolvedTarget = URL(filePath: target, relativeTo: url.deletingLastPathComponent())
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let physicalTreeRoot = try physicalPath(treeRoot.path)
            let physicalTarget = try physicalPath(resolvedTarget.path)
            guard physicalTarget == physicalTreeRoot || physicalTarget.hasPrefix(physicalTreeRoot + "/") else {
                throw ValidationError("A release artifact symbolic link escapes its bound tree.")
            }
            entry = InventoryEntry(path: relativePath,
                                   kind: .symbolicLink,
                                   device: device,
                                   inode: inode,
                                   permissions: permissions,
                                   size: nil,
                                   sha256: sha256(Data(target.utf8)),
                                   symbolicLinkTarget: target)
        default:
            throw ValidationError("A release artifact contains an unsupported file type at \(url.path).")
        }

        let attributesAfter = try fileManager.attributesOfItem(atPath: url.path)
        guard try stableAttributes(attributesAfter, equal: attributesBefore, path: url.path) else {
            throw ValidationError("A release artifact entry changed during inventory at \(url.path).")
        }
        return entry
    }

    private static func rootIdentity(at url: URL, fileManager: FileManager) throws -> RootIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw JunchatReleasePreflight.PreflightError.invalidArtifactStructure(path: url.path)
        }
        return try RootIdentity(path: url.path,
                                device: unsignedAttribute(.systemNumber, in: attributes, path: url.path),
                                inode: unsignedAttribute(.systemFileNumber, in: attributes, path: url.path),
                                permissions: UInt16(truncatingIfNeeded: unsignedAttribute(.posixPermissions,
                                                                                          in: attributes,
                                                                                          path: url.path)))
    }

    private static func writeBinding(_ binding: ReleaseArtifactBinding,
                                     to bindingURL: URL,
                                     fileManager: FileManager) throws -> String {
        let canonicalURL = try canonicalBindingURL(path: bindingURL.path,
                                                   fileManager: fileManager,
                                                   requireExistingFile: false)
        let archivePath = binding.archiveRoot.path
        guard canonicalURL.path != archivePath,
              !canonicalURL.path.hasPrefix(archivePath + "/") else {
            throw ValidationError("The release artifact binding must be outside the archive it binds.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(binding)
        let digest = sha256(data)
        let temporaryURL = canonicalURL.deletingLastPathComponent()
            .appending(path: ".\(canonicalURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path,
                                     contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw ValidationError("Could not create the private release artifact binding.")
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try fileManager.moveItem(at: temporaryURL, to: canonicalURL)
        _ = try privateBindingAttributes(at: canonicalURL, fileManager: fileManager)
        return digest
    }

    private static func canonicalBindingURL(path: String,
                                            fileManager: FileManager,
                                            requireExistingFile: Bool) throws -> URL {
        guard !path.isEmpty, NSString(string: path).isAbsolutePath else {
            throw ValidationError("The release artifact binding path must be canonical and absolute.")
        }
        let url = URL(filePath: path)
        let parentURL = url.deletingLastPathComponent()
        guard path == url.path,
              path == url.standardizedFileURL.path,
              parentURL.path == parentURL.resolvingSymlinksInPath().path else {
            throw ValidationError("The release artifact binding path must be canonical and absolute.")
        }
        let parentAttributes = try fileManager.attributesOfItem(atPath: parentURL.path)
        let parentPermissions = try unsignedAttribute(.posixPermissions,
                                                      in: parentAttributes,
                                                      path: parentURL.path)
        guard parentAttributes[.type] as? FileAttributeType == .typeDirectory,
              parentPermissions & 0o077 == 0 else {
            throw ValidationError("The release artifact binding directory must be private.")
        }

        if requireExistingFile {
            guard url.resolvingSymlinksInPath().path == path else {
                throw ValidationError("The release artifact binding must not be a symbolic link.")
            }
            _ = try privateBindingAttributes(at: url, fileManager: fileManager)
        } else if fileManager.fileExists(atPath: path) {
            throw ValidationError("The release artifact binding path already exists.")
        }
        return url
    }

    private static func privateBindingAttributes(at url: URL,
                                                 fileManager: FileManager) throws -> BindingFileAttributes {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = try unsignedAttribute(.posixPermissions, in: attributes, path: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              permissions & 0o077 == 0 else {
            throw ValidationError("The release artifact binding must be a private regular file.")
        }
        return try BindingFileAttributes(device: unsignedAttribute(.systemNumber, in: attributes, path: url.path),
                                         inode: unsignedAttribute(.systemFileNumber, in: attributes, path: url.path),
                                         size: unsignedAttribute(.size, in: attributes, path: url.path),
                                         permissions: UInt16(truncatingIfNeeded: permissions))
    }

    // MARK: - Filesystem helpers

    private static func canonicalArtifactURL(variable: String,
                                             environment: [String: String],
                                             expectedExtension: String) throws -> URL {
        guard let path = environment[variable],
              !path.isEmpty,
              NSString(string: path).isAbsolutePath else {
            throw JunchatReleasePreflight.PreflightError.invalidArtifactPath(variable: variable)
        }
        let url = URL(filePath: path)
        guard path == url.path,
              path == url.standardizedFileURL.path,
              path == url.resolvingSymlinksInPath().path,
              url.pathExtension == expectedExtension else {
            throw JunchatReleasePreflight.PreflightError.invalidArtifactPath(variable: variable)
        }
        return url
    }

    private static func requireDirectory(_ url: URL, fileManager: FileManager) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory else {
            throw JunchatReleasePreflight.PreflightError.invalidArtifactStructure(path: url.path)
        }
    }

    private static func requireRegularFile(_ url: URL, fileManager: FileManager) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              let size = attributes?[.size] as? NSNumber,
              size.uint64Value > 0 else {
            throw JunchatReleasePreflight.PreflightError.invalidArtifactStructure(path: url.path)
        }
    }

    private static func propertyList(at url: URL, fileManager: FileManager) throws -> [String: Any] {
        try requireRegularFile(url, fileManager: fileManager)
        do {
            let data = try Data(contentsOf: url)
            guard let propertyList = try PropertyListSerialization.propertyList(from: data,
                                                                                options: [],
                                                                                format: nil) as? [String: Any] else {
                throw JunchatReleasePreflight.PreflightError.invalidPropertyList(path: url.path)
            }
            return propertyList
        } catch let error as JunchatReleasePreflight.PreflightError {
            throw error
        } catch {
            throw JunchatReleasePreflight.PreflightError.invalidPropertyList(path: url.path)
        }
    }

    private static func unsignedAttribute(_ key: FileAttributeKey,
                                          in attributes: [FileAttributeKey: Any],
                                          path: String) throws -> UInt64 {
        guard let value = attributes[key] as? NSNumber else {
            throw ValidationError("Could not read release artifact identity at \(path).")
        }
        return value.uint64Value
    }

    private static func stableAttributes(_ lhs: [FileAttributeKey: Any],
                                         equal rhs: [FileAttributeKey: Any],
                                         path: String) throws -> Bool {
        guard lhs[.type] as? FileAttributeType == rhs[.type] as? FileAttributeType else {
            return false
        }
        for key in [FileAttributeKey.systemNumber, .systemFileNumber, .posixPermissions, .size] {
            guard try unsignedAttribute(key, in: lhs, path: path) == unsignedAttribute(key, in: rhs, path: path) else {
                return false
            }
        }
        return true
    }

    private static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isASCII && (character.isNumber || ("a"..."f").contains(character))
        }
    }

    private static func physicalPath(_ path: String) throws -> String {
        guard let resolvedPath = Darwin.realpath(path, nil) else {
            throw ValidationError("Could not resolve release artifact path \(path).")
        }
        defer { Darwin.free(resolvedPath) }
        return String(cString: resolvedPath)
    }
}
