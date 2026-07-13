import Foundation

struct JunchatReleaseVersion: Equatable {
    enum VersionError: LocalizedError {
        case invalidMarketingVersion(String)
        case invalidBuildNumber(String)
        case invalidMetadataCount(field: String)
        case marketingVersionDecreased
        case buildNumberDidNotIncrease
        case exactNoOpNotAllowed
        case versionOverflow
        case roundTripFailed

        var errorDescription: String? {
            switch self {
            case .invalidMarketingVersion(let value):
                "Marketing version must use MAJOR.MINOR.PATCH semantic versioning: \(value)"
            case .invalidBuildNumber(let value):
                "Build number must be a positive integer: \(value)"
            case .invalidMetadataCount(let field):
                "project.yml must contain exactly one \(field) field"
            case .marketingVersionDecreased:
                "Marketing version must not decrease"
            case .buildNumberDidNotIncrease:
                "Build number must increase"
            case .exactNoOpNotAllowed:
                "Version metadata already matches the requested values"
            case .versionOverflow:
                "Version metadata cannot be incremented without overflowing"
            case .roundTripFailed:
                "Updated project.yml version metadata did not round-trip"
            }
        }
    }

    let name: String
    let build: Int

    private static let marketingVersionPattern = try! NSRegularExpression(pattern: #"(?m)^[ \t]*MARKETING_VERSION[ \t]*:[ \t]*(\S+)[ \t]*$"#)
    private static let buildNumberPattern = try! NSRegularExpression(pattern: #"(?m)^[ \t]*CURRENT_PROJECT_VERSION[ \t]*:[ \t]*([0-9]+)[ \t]*$"#)

    static func parse(_ projectYAML: String) throws -> JunchatReleaseVersion {
        let name = try singleValue(matching: marketingVersionPattern,
                                   in: projectYAML,
                                   field: "MARKETING_VERSION")
        let buildValue = try singleValue(matching: buildNumberPattern,
                                         in: projectYAML,
                                         field: "CURRENT_PROJECT_VERSION")
        guard let build = Int(buildValue), build > 0 else {
            throw VersionError.invalidBuildNumber(buildValue)
        }
        _ = try semanticComponents(name)
        return JunchatReleaseVersion(name: name, build: build)
    }

    static func updatedProjectYAML(_ projectYAML: String,
                                   name: String,
                                   build: Int,
                                   allowExactNoOp: Bool = false) throws -> String {
        let current = try parse(projectYAML)
        let currentComponents = try semanticComponents(current.name)
        let targetComponents = try semanticComponents(name)
        guard build > 0 else {
            throw VersionError.invalidBuildNumber(String(build))
        }

        if current == JunchatReleaseVersion(name: name, build: build) {
            guard allowExactNoOp else {
                throw VersionError.exactNoOpNotAllowed
            }
            return projectYAML
        }

        guard !isOrderedBefore(targetComponents, currentComponents) else {
            throw VersionError.marketingVersionDecreased
        }
        guard build > current.build else {
            throw VersionError.buildNumberDidNotIncrease
        }

        let updatedName = try replacingSingleValue(matching: marketingVersionPattern,
                                                   in: projectYAML,
                                                   field: "MARKETING_VERSION",
                                                   with: name)
        let updated = try replacingSingleValue(matching: buildNumberPattern,
                                               in: updatedName,
                                               field: "CURRENT_PROJECT_VERSION",
                                               with: String(build))

        guard try parse(updated) == JunchatReleaseVersion(name: name, build: build) else {
            throw VersionError.roundTripFailed
        }
        return updated
    }

    @discardableResult
    static func updateProjectFile(at url: URL,
                                  name: String,
                                  build: Int,
                                  allowExactNoOp: Bool = true) throws -> Bool {
        let source = try String(contentsOf: url, encoding: .utf8)
        let updated = try updatedProjectYAML(source,
                                             name: name,
                                             build: build,
                                             allowExactNoOp: allowExactNoOp)
        guard updated != source else { return false }

        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        try Data(updated.utf8).write(to: url, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return true
    }

    func nextPatch() throws -> JunchatReleaseVersion {
        let components = try Self.semanticComponents(name)
        let (nextPatch, overflowed) = components.patch.addingReportingOverflow(1)
        let (nextBuild, buildOverflowed) = build.addingReportingOverflow(1)
        guard !overflowed, !buildOverflowed else {
            throw VersionError.versionOverflow
        }
        return JunchatReleaseVersion(name: "\(components.major).\(components.minor).\(nextPatch)",
                                     build: nextBuild)
    }

    static func validateMarketingVersion(_ value: String) throws {
        _ = try semanticComponents(value)
    }

    private static func semanticComponents(_ value: String) throws -> (major: Int, minor: Int, patch: Int) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw VersionError.invalidMarketingVersion(value)
        }

        let numbers = try parts.map { part -> Int in
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0",
                  let number = Int(part) else {
                throw VersionError.invalidMarketingVersion(value)
            }
            return number
        }
        return (numbers[0], numbers[1], numbers[2])
    }

    private static func isOrderedBefore(_ lhs: (major: Int, minor: Int, patch: Int),
                                        _ rhs: (major: Int, minor: Int, patch: Int)) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func singleValue(matching expression: NSRegularExpression,
                                    in source: String,
                                    field: String) throws -> String {
        let matches = expression.matches(in: source,
                                         range: NSRange(source.startIndex..., in: source))
        guard matches.count == 1,
              let range = Range(matches[0].range(at: 1), in: source) else {
            throw VersionError.invalidMetadataCount(field: field)
        }
        return String(source[range])
    }

    private static func replacingSingleValue(matching expression: NSRegularExpression,
                                             in source: String,
                                             field: String,
                                             with replacement: String) throws -> String {
        let matches = expression.matches(in: source,
                                         range: NSRange(source.startIndex..., in: source))
        guard matches.count == 1,
              let range = Range(matches[0].range(at: 1), in: source) else {
            throw VersionError.invalidMetadataCount(field: field)
        }
        var updated = source
        updated.replaceSubrange(range, with: replacement)
        return updated
    }
}
