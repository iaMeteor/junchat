import Foundation

enum JunchatReleaseFile {
    struct Snapshot {
        let url: URL
        let data: Data
        let permissions: Int

        init(url: URL) throws {
            self.url = url
            data = try Data(contentsOf: url)
            permissions = try JunchatReleaseFile.permissions(at: url)
        }

        func restore() throws {
            try JunchatReleaseFile.write(data, to: url, permissions: permissions)
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        try write(data, to: url, permissions: permissions(at: url))
    }

    static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    private static func write(_ data: Data, to url: URL, permissions: Int) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return permissions.intValue
    }
}
