/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import CryptoKit
import Foundation
import zlib

struct ElementCallCandidateAARExpectedFile: Equatable {
    let path: String
    let sha256: String
    let size: Int64
}

enum ElementCallCandidateAAR {
    private static let embeddedPrefix = "assets/element-call/"
    private static let maximumArchiveBytes = 1024 * 1024 * 1024
    private static let maximumEntryBytes = 512 * 1024 * 1024
    private static let maximumExpandedBytes = 1024 * 1024 * 1024
    private static let maximumZIPCommentBytes = 65535
    private static let inflateChunkBytes = 64 * 1024

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let dataDescriptorSignature: UInt32 = 0x0807_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    private static let dataDescriptorFlag: UInt16 = 1 << 3
    private static let UTF8Flag: UInt16 = 1 << 11
    private static let supportedFlags: UInt16 = 0x080E

    private static let ZIP64ExtraField: UInt16 = 0x0001
    private static let strongEncryptionExtraField: UInt16 = 0x0017
    private static let unicodePathExtraField: UInt16 = 0x7075
    private static let AESEncryptionExtraField: UInt16 = 0x9901

    static func verify(_ snapshot: Data,
                       expectedEmbeddedFiles: [ElementCallCandidateAARExpectedFile]) throws {
        try require(!snapshot.isEmpty && snapshot.count <= maximumArchiveBytes,
                    "The Android AAR is empty or exceeds the supported archive size.")

        let expected = try validateExpectedFiles(expectedEmbeddedFiles)
        let archive = ArchiveBytes(snapshot)
        let endRecord = try parseEndRecord(in: archive)
        let entries = try parseCentralDirectory(endRecord: endRecord, in: archive)
        let localEntries = try entries.map { try parseLocalEntry($0, centralOffset: endRecord.centralOffset, in: archive) }
        try validatePathTree(entries)
        try validateLocalLayout(localEntries, centralOffset: endRecord.centralOffset)

        var observedEmbeddedPaths = Set<String>()
        for localEntry in localEntries {
            let contents = try extract(localEntry, from: snapshot)
            try require(contents.count == localEntry.entry.uncompressedSize,
                        "The Android AAR entry size does not match its declaration: \(localEntry.entry.name).")
            try require(crc32(contents) == localEntry.entry.crc32,
                        "The Android AAR entry CRC-32 does not match: \(localEntry.entry.name).")

            guard localEntry.entry.kind == .file,
                  localEntry.entry.name.hasPrefix(embeddedPrefix) else {
                continue
            }

            let relativePath = String(localEntry.entry.name.dropFirst(embeddedPrefix.count))
            try require(!relativePath.isEmpty,
                        "The Android AAR contains a file at the embedded web directory path.")
            guard let expectedFile = expected[relativePath] else {
                throw ElementCallCandidateError.validation("The Android AAR contains an unexpected embedded web file: \(relativePath).")
            }
            try require(observedEmbeddedPaths.insert(relativePath).inserted,
                        "The Android AAR contains a duplicate embedded web file: \(relativePath).")
            try require(Int64(contents.count) == expectedFile.size,
                        "The Android AAR embedded web file size does not match: \(relativePath).")
            try require(sha256(contents) == expectedFile.sha256,
                        "The Android AAR embedded web file SHA-256 does not match: \(relativePath).")
        }

        let missingPaths = Set(expected.keys).subtracting(observedEmbeddedPaths).sorted()
        try require(missingPaths.isEmpty,
                    "The Android AAR is missing embedded web files: \(missingPaths.joined(separator: ", ")).")
    }

    private enum EntryKind: Equatable {
        case file
        case directory
    }

    private struct EndRecord {
        let offset: Int
        let entryCount: Int
        let centralOffset: Int
        let centralSize: Int
    }

    private struct CentralEntry {
        let name: String
        let canonicalPath: String
        let rawName: Data
        let kind: EntryKind
        let versionNeeded: UInt16
        let flags: UInt16
        let compressionMethod: UInt16
        let modificationTime: UInt16
        let modificationDate: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private struct LocalEntry {
        let entry: CentralEntry
        let dataRange: Range<Int>
        let occupiedRange: Range<Int>
    }

    private struct ArchiveBytes {
        let data: Data

        init(_ data: Data) {
            self.data = data
        }

        var count: Int {
            data.count
        }

        func uint16(at offset: Int, limit: Int? = nil) throws -> UInt16 {
            let range = try range(at: offset, length: 2, limit: limit)
            let first = data[data.index(data.startIndex, offsetBy: range.lowerBound)]
            let second = data[data.index(data.startIndex, offsetBy: range.lowerBound + 1)]
            return UInt16(first) | UInt16(second) << 8
        }

        func uint32(at offset: Int, limit: Int? = nil) throws -> UInt32 {
            let range = try range(at: offset, length: 4, limit: limit)
            let start = data.index(data.startIndex, offsetBy: range.lowerBound)
            return UInt32(data[start]) |
                UInt32(data[data.index(start, offsetBy: 1)]) << 8 |
                UInt32(data[data.index(start, offsetBy: 2)]) << 16 |
                UInt32(data[data.index(start, offsetBy: 3)]) << 24
        }

        func bytes(in range: Range<Int>) throws -> Data {
            _ = try self.range(at: range.lowerBound, length: range.count)
            let lowerBound = data.index(data.startIndex, offsetBy: range.lowerBound)
            let upperBound = data.index(lowerBound, offsetBy: range.count)
            return data[lowerBound..<upperBound]
        }

        func range(at offset: Int, length: Int, limit: Int? = nil) throws -> Range<Int> {
            let upperLimit = limit ?? count
            let (end, overflow) = offset.addingReportingOverflow(length)
            try require(offset >= 0 && length >= 0 && !overflow && end <= upperLimit && upperLimit <= count,
                        "The Android AAR contains an out-of-bounds ZIP record.")
            return offset..<end
        }
    }

    private static func validateExpectedFiles(_ files: [ElementCallCandidateAARExpectedFile]) throws
        -> [String: ElementCallCandidateAARExpectedFile] {
        var result = [String: ElementCallCandidateAARExpectedFile]()
        var totalSize = 0
        for file in files {
            _ = try validatePath(file.path, directory: false, label: "expected embedded web path")
            try require(isLowercaseSHA256(file.sha256),
                        "An expected Android embedded web SHA-256 is invalid: \(file.path).")
            try require(file.size >= 0 && file.size <= Int64(maximumEntryBytes),
                        "An expected Android embedded web file size is unsupported: \(file.path).")
            let (newTotal, overflow) = totalSize.addingReportingOverflow(Int(file.size))
            try require(!overflow && newTotal <= maximumExpandedBytes,
                        "The expected Android embedded web files exceed the supported expanded size.")
            totalSize = newTotal
            try require(result.updateValue(file, forKey: file.path) == nil,
                        "The expected Android embedded web files contain a duplicate path: \(file.path).")
        }
        return result
    }

    private static func parseEndRecord(in archive: ArchiveBytes) throws -> EndRecord {
        let fixedSize = 22
        try require(archive.count >= fixedSize, "The Android AAR is truncated before its ZIP end record.")
        let minimumOffset = max(0, archive.count - fixedSize - maximumZIPCommentBytes)
        var endOffset: Int?
        for candidate in stride(from: archive.count - fixedSize, through: minimumOffset, by: -1) {
            guard try archive.uint32(at: candidate) == endOfCentralDirectorySignature else { continue }
            let commentLength = try Int(archive.uint16(at: candidate + 20))
            guard candidate + fixedSize + commentLength == archive.count else { continue }
            endOffset = candidate
            break
        }
        guard let endOffset else {
            throw ElementCallCandidateError.validation("The Android AAR has no complete ZIP end-of-central-directory record.")
        }

        let diskNumber = try archive.uint16(at: endOffset + 4)
        let centralDiskNumber = try archive.uint16(at: endOffset + 6)
        let diskEntryCount = try archive.uint16(at: endOffset + 8)
        let totalEntryCount = try archive.uint16(at: endOffset + 10)
        let centralSize = try archive.uint32(at: endOffset + 12)
        let centralOffset = try archive.uint32(at: endOffset + 16)

        try require(diskNumber == 0 && centralDiskNumber == 0 && diskEntryCount == totalEntryCount,
                    "The Android AAR uses an unsupported multi-disk ZIP layout.")
        try require(totalEntryCount != UInt16.max && centralSize != UInt32.max && centralOffset != UInt32.max,
                    "The Android AAR uses unsupported ZIP64 records.")

        let centralOffsetValue = Int(centralOffset)
        let centralSizeValue = Int(centralSize)
        let centralRange = try archive.range(at: centralOffsetValue, length: centralSizeValue, limit: endOffset)
        try require(centralRange.upperBound == endOffset,
                    "The Android AAR central directory does not end at the ZIP end record.")
        return EndRecord(offset: endOffset,
                         entryCount: Int(totalEntryCount),
                         centralOffset: centralOffsetValue,
                         centralSize: centralSizeValue)
    }

    private static func parseCentralDirectory(endRecord: EndRecord,
                                              in archive: ArchiveBytes) throws -> [CentralEntry] {
        let centralEnd = endRecord.centralOffset + endRecord.centralSize
        var cursor = endRecord.centralOffset
        var entries = [CentralEntry]()
        entries.reserveCapacity(endRecord.entryCount)
        var canonicalPaths = Set<String>()
        var expandedSize = 0

        for index in 0..<endRecord.entryCount {
            _ = try archive.range(at: cursor, length: 46, limit: centralEnd)
            let signature = try archive.uint32(at: cursor, limit: centralEnd)
            try require(signature == centralHeaderSignature,
                        "The Android AAR central directory entry \(index) is malformed.")

            let versionMadeBy = try archive.uint16(at: cursor + 4, limit: centralEnd)
            let versionNeeded = try archive.uint16(at: cursor + 6, limit: centralEnd)
            let flags = try archive.uint16(at: cursor + 8, limit: centralEnd)
            let compressionMethod = try archive.uint16(at: cursor + 10, limit: centralEnd)
            let modificationTime = try archive.uint16(at: cursor + 12, limit: centralEnd)
            let modificationDate = try archive.uint16(at: cursor + 14, limit: centralEnd)
            let checksum = try archive.uint32(at: cursor + 16, limit: centralEnd)
            let compressedSize = try archive.uint32(at: cursor + 20, limit: centralEnd)
            let uncompressedSize = try archive.uint32(at: cursor + 24, limit: centralEnd)
            let nameLength = try Int(archive.uint16(at: cursor + 28, limit: centralEnd))
            let extraLength = try Int(archive.uint16(at: cursor + 30, limit: centralEnd))
            let commentLength = try Int(archive.uint16(at: cursor + 32, limit: centralEnd))
            let startingDisk = try archive.uint16(at: cursor + 34, limit: centralEnd)
            let externalAttributes = try archive.uint32(at: cursor + 38, limit: centralEnd)
            let localHeaderOffset = try archive.uint32(at: cursor + 42, limit: centralEnd)

            try validateFlags(flags, compressionMethod: compressionMethod)
            try validateVersion(versionNeeded, compressionMethod: compressionMethod)
            try require(compressedSize != UInt32.max && uncompressedSize != UInt32.max &&
                localHeaderOffset != UInt32.max && startingDisk != UInt16.max,
                "The Android AAR uses unsupported ZIP64 entry fields.")
            try require(startingDisk == 0, "The Android AAR contains an entry from another ZIP disk.")
            try require(nameLength > 0, "The Android AAR contains an entry with an empty name.")

            let variableStart = cursor + 46
            let nameRange = try archive.range(at: variableStart, length: nameLength, limit: centralEnd)
            let extraRange = try archive.range(at: nameRange.upperBound, length: extraLength, limit: centralEnd)
            let entryEnd = try archive.range(at: extraRange.upperBound, length: commentLength, limit: centralEnd).upperBound
            let rawName = try archive.bytes(in: nameRange)
            let name = try decodeName(rawName, flags: flags)
            let kind = try classifyEntry(name: name,
                                         versionMadeBy: versionMadeBy,
                                         externalAttributes: externalAttributes)
            let canonicalPath = try validatePath(name, directory: kind == .directory, label: "ZIP entry path")
            try require(canonicalPaths.insert(canonicalPath).inserted,
                        "The Android AAR contains a duplicate ZIP entry path: \(canonicalPath).")
            try validateExtraFields(extraRange, in: archive)

            let compressedSizeValue = Int(compressedSize)
            let uncompressedSizeValue = Int(uncompressedSize)
            try require(uncompressedSizeValue <= maximumEntryBytes,
                        "The Android AAR entry exceeds the supported expanded size: \(name).")
            let (newExpandedSize, overflow) = expandedSize.addingReportingOverflow(uncompressedSizeValue)
            try require(!overflow && newExpandedSize <= maximumExpandedBytes,
                        "The Android AAR exceeds the supported total expanded size.")
            expandedSize = newExpandedSize
            if compressionMethod == 0 {
                try require(compressedSizeValue == uncompressedSizeValue,
                            "A stored Android AAR entry has inconsistent sizes: \(name).")
            }
            if kind == .directory {
                try require(uncompressedSizeValue == 0 && checksum == 0,
                            "An Android AAR directory entry contains file data: \(name).")
            }
            try require(Int(localHeaderOffset) < endRecord.centralOffset,
                        "An Android AAR local header points into its central directory: \(name).")

            entries.append(CentralEntry(name: name,
                                        canonicalPath: canonicalPath,
                                        rawName: rawName,
                                        kind: kind,
                                        versionNeeded: versionNeeded,
                                        flags: flags,
                                        compressionMethod: compressionMethod,
                                        modificationTime: modificationTime,
                                        modificationDate: modificationDate,
                                        crc32: checksum,
                                        compressedSize: compressedSizeValue,
                                        uncompressedSize: uncompressedSizeValue,
                                        localHeaderOffset: Int(localHeaderOffset)))
            cursor = entryEnd
        }

        try require(cursor == centralEnd,
                    "The Android AAR central directory size or entry count is inconsistent.")
        return entries
    }

    private static func parseLocalEntry(_ entry: CentralEntry,
                                        centralOffset: Int,
                                        in archive: ArchiveBytes) throws -> LocalEntry {
        let offset = entry.localHeaderOffset
        _ = try archive.range(at: offset, length: 30, limit: centralOffset)
        let signature = try archive.uint32(at: offset, limit: centralOffset)
        try require(signature == localHeaderSignature,
                    "The Android AAR local header is malformed: \(entry.name).")

        let versionNeeded = try archive.uint16(at: offset + 4, limit: centralOffset)
        let flags = try archive.uint16(at: offset + 6, limit: centralOffset)
        let compressionMethod = try archive.uint16(at: offset + 8, limit: centralOffset)
        let modificationTime = try archive.uint16(at: offset + 10, limit: centralOffset)
        let modificationDate = try archive.uint16(at: offset + 12, limit: centralOffset)
        let checksum = try archive.uint32(at: offset + 14, limit: centralOffset)
        let compressedSize = try archive.uint32(at: offset + 18, limit: centralOffset)
        let uncompressedSize = try archive.uint32(at: offset + 22, limit: centralOffset)
        let nameLength = try Int(archive.uint16(at: offset + 26, limit: centralOffset))
        let extraLength = try Int(archive.uint16(at: offset + 28, limit: centralOffset))

        try require(versionNeeded == entry.versionNeeded && flags == entry.flags &&
            compressionMethod == entry.compressionMethod && modificationTime == entry.modificationTime &&
            modificationDate == entry.modificationDate,
            "The Android AAR local and central ZIP headers disagree: \(entry.name).")

        let nameRange = try archive.range(at: offset + 30, length: nameLength, limit: centralOffset)
        let extraRange = try archive.range(at: nameRange.upperBound, length: extraLength, limit: centralOffset)
        let rawName = try archive.bytes(in: nameRange)
        try require(rawName == entry.rawName,
                    "The Android AAR local and central entry names disagree: \(entry.name).")
        try validateExtraFields(extraRange, in: archive)

        let usesDescriptor = flags & dataDescriptorFlag != 0
        if usesDescriptor {
            try require((checksum == 0 || checksum == entry.crc32) &&
                (compressedSize == 0 || compressedSize == UInt32(entry.compressedSize)) &&
                (uncompressedSize == 0 || uncompressedSize == UInt32(entry.uncompressedSize)),
                "The Android AAR local ZIP size placeholders are invalid: \(entry.name).")
        } else {
            try require(checksum == entry.crc32 && compressedSize == UInt32(entry.compressedSize) &&
                uncompressedSize == UInt32(entry.uncompressedSize),
                "The Android AAR local and central ZIP sizes or CRC disagree: \(entry.name).")
        }

        let dataRange = try archive.range(at: extraRange.upperBound,
                                          length: entry.compressedSize,
                                          limit: centralOffset)
        let descriptorLength = usesDescriptor
            ? try parseDataDescriptor(at: dataRange.upperBound, entry: entry, centralOffset: centralOffset, in: archive)
            : 0
        let occupiedRange = try archive.range(at: offset,
                                              length: dataRange.upperBound - offset + descriptorLength,
                                              limit: centralOffset)
        return LocalEntry(entry: entry, dataRange: dataRange, occupiedRange: occupiedRange)
    }

    private static func parseDataDescriptor(at offset: Int,
                                            entry: CentralEntry,
                                            centralOffset: Int,
                                            in archive: ArchiveBytes) throws -> Int {
        let unsignedMatches: Bool
        if offset <= centralOffset - 12 {
            unsignedMatches = try archive.uint32(at: offset, limit: centralOffset) == entry.crc32 &&
                archive.uint32(at: offset + 4, limit: centralOffset) == UInt32(entry.compressedSize) &&
                archive.uint32(at: offset + 8, limit: centralOffset) == UInt32(entry.uncompressedSize)
        } else {
            unsignedMatches = false
        }

        let signedMatches: Bool
        if offset <= centralOffset - 16 {
            signedMatches = try archive.uint32(at: offset, limit: centralOffset) == dataDescriptorSignature &&
                archive.uint32(at: offset + 4, limit: centralOffset) == entry.crc32 &&
                archive.uint32(at: offset + 8, limit: centralOffset) == UInt32(entry.compressedSize) &&
                archive.uint32(at: offset + 12, limit: centralOffset) == UInt32(entry.uncompressedSize)
        } else {
            signedMatches = false
        }

        try require(unsignedMatches != signedMatches,
                    "The Android AAR data descriptor is missing, malformed, or ambiguous: \(entry.name).")
        return signedMatches ? 16 : 12
    }

    private static func validateLocalLayout(_ entries: [LocalEntry], centralOffset: Int) throws {
        let ranges = entries.map(\.occupiedRange).sorted { $0.lowerBound < $1.lowerBound }
        guard let first = ranges.first else {
            try require(centralOffset == 0, "The Android AAR contains unreferenced bytes before its central directory.")
            return
        }
        try require(first.lowerBound == 0,
                    "The Android AAR contains an unsupported prefix before its first local ZIP record.")
        var previousEnd = first.upperBound
        for range in ranges.dropFirst() {
            try require(range.lowerBound >= previousEnd, "The Android AAR local ZIP records overlap.")
            try require(range.lowerBound == previousEnd, "The Android AAR contains bytes outside its local ZIP records.")
            previousEnd = range.upperBound
        }
        try require(previousEnd == centralOffset,
                    "The Android AAR contains bytes between its local records and central directory.")
    }

    private static func validatePathTree(_ entries: [CentralEntry]) throws {
        let kinds = Dictionary(uniqueKeysWithValues: entries.map { ($0.canonicalPath, $0.kind) })
        for entry in entries {
            let components = entry.canonicalPath.split(separator: "/")
            guard components.count > 1 else { continue }
            for componentCount in 1..<components.count {
                let ancestor = components.prefix(componentCount).joined(separator: "/")
                try require(kinds[ancestor] != .file,
                            "The Android AAR places an entry below a regular file: \(entry.name).")
            }
        }
    }

    private static func classifyEntry(name: String,
                                      versionMadeBy: UInt16,
                                      externalAttributes: UInt32) throws -> EntryKind {
        let hasDirectorySuffix = name.hasSuffix("/")
        let hostSystem = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
        let dosAttributes = UInt8(truncatingIfNeeded: externalAttributes)
        let hasDOSDirectoryAttribute = dosAttributes & 0x10 != 0
        try require(dosAttributes & 0x08 == 0,
                    "The Android AAR contains an unsupported volume-label entry: \(name).")

        if hostSystem == 3 || hostSystem == 19 {
            let unixMode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
            switch unixMode & 0xF000 {
            case 0:
                break
            case 0x4000:
                try require(hasDirectorySuffix, "An Android AAR directory entry has a noncanonical name: \(name).")
                return .directory
            case 0x8000:
                try require(!hasDirectorySuffix && !hasDOSDirectoryAttribute,
                            "An Android AAR regular file has conflicting file type metadata: \(name).")
                return .file
            case 0xA000:
                throw ElementCallCandidateError.validation("The Android AAR contains an unsupported symbolic link: \(name).")
            default:
                throw ElementCallCandidateError.validation("The Android AAR contains an unsupported Unix entry type: \(name).")
            }
        }

        try require(!hasDOSDirectoryAttribute || hasDirectorySuffix,
                    "An Android AAR directory entry has a noncanonical name: \(name).")
        return hasDirectorySuffix ? .directory : .file
    }

    private static func decodeName(_ rawName: Data, flags: UInt16) throws -> String {
        if flags & UTF8Flag == 0 {
            try require(rawName.allSatisfy { $0 < 0x80 },
                        "The Android AAR contains a non-ASCII name without the ZIP UTF-8 flag.")
        }
        guard let name = String(data: rawName, encoding: .utf8) else {
            throw ElementCallCandidateError.validation("The Android AAR contains an invalid UTF-8 entry name.")
        }
        return name
    }

    @discardableResult
    private static func validatePath(_ path: String, directory: Bool, label: String) throws -> String {
        try require(!path.isEmpty && path.precomposedStringWithCanonicalMapping == path &&
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            "The Android AAR \(label) is empty, contains control characters, or is not Unicode-normalized: \(path).")
        try require(!path.hasPrefix("/") && !path.contains("\\"),
                    "The Android AAR \(label) must be a relative POSIX path: \(path).")
        try require(directory == path.hasSuffix("/"),
                    "The Android AAR \(label) has an invalid directory suffix: \(path).")

        let canonicalPath = directory ? String(path.dropLast()) : path
        let components = canonicalPath.split(separator: "/", omittingEmptySubsequences: false)
        try require(!canonicalPath.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },
                    "The Android AAR \(label) contains traversal or noncanonical components: \(path).")
        return canonicalPath
    }

    private static func validateFlags(_ flags: UInt16, compressionMethod: UInt16) throws {
        try require(flags & 0x0001 == 0 && flags & 0x0040 == 0,
                    "The Android AAR contains an encrypted ZIP entry.")
        try require(flags & ~supportedFlags == 0,
                    "The Android AAR uses unsupported general-purpose ZIP flags.")
        try require(compressionMethod == 0 || compressionMethod == 8,
                    "The Android AAR uses an unsupported ZIP compression method: \(compressionMethod).")
        if compressionMethod == 0 {
            try require(flags & 0x0006 == 0, "A stored Android AAR entry uses invalid compression flags.")
        }
    }

    private static func validateVersion(_ version: UInt16, compressionMethod: UInt16) throws {
        let minimumVersion: UInt16 = compressionMethod == 0 ? 10 : 20
        try require(version >= minimumVersion && version <= 20,
                    "The Android AAR entry requires an unsupported ZIP version: \(version).")
    }

    private static func validateExtraFields(_ range: Range<Int>, in archive: ArchiveBytes) throws {
        var cursor = range.lowerBound
        var identifiers = Set<UInt16>()
        while cursor < range.upperBound {
            _ = try archive.range(at: cursor, length: 4, limit: range.upperBound)
            let identifier = try archive.uint16(at: cursor, limit: range.upperBound)
            let length = try Int(archive.uint16(at: cursor + 2, limit: range.upperBound))
            let fieldRange = try archive.range(at: cursor + 4, length: length, limit: range.upperBound)
            try require(identifiers.insert(identifier).inserted,
                        "The Android AAR contains duplicate ZIP extra fields.")
            switch identifier {
            case ZIP64ExtraField:
                throw ElementCallCandidateError.validation("The Android AAR contains an unsupported ZIP64 extra field.")
            case strongEncryptionExtraField, AESEncryptionExtraField:
                throw ElementCallCandidateError.validation("The Android AAR contains unsupported ZIP encryption metadata.")
            case unicodePathExtraField:
                throw ElementCallCandidateError.validation("The Android AAR contains an ambiguous Unicode path extra field.")
            default:
                break
            }
            cursor = fieldRange.upperBound
        }
    }

    private static func extract(_ localEntry: LocalEntry, from snapshot: Data) throws -> Data {
        let lowerBound = snapshot.index(snapshot.startIndex, offsetBy: localEntry.dataRange.lowerBound)
        let upperBound = snapshot.index(lowerBound, offsetBy: localEntry.dataRange.count)
        let compressed = snapshot[lowerBound..<upperBound]
        switch localEntry.entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflateRaw(compressed,
                                  expectedSize: localEntry.entry.uncompressedSize,
                                  name: localEntry.entry.name)
        default:
            throw ElementCallCandidateError.validation("The Android AAR uses an unsupported ZIP compression method.")
        }
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int, name: String) throws -> Data {
        var stream = z_stream()
        let initialization = inflateInit2_(&stream,
                                           -MAX_WBITS,
                                           ZLIB_VERSION,
                                           Int32(MemoryLayout<z_stream>.size))
        try require(initialization == Z_OK, "Unable to initialize raw DEFLATE verification for the Android AAR.")
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(min(expectedSize, inflateChunkBytes))
        try compressed.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(compressed.count)
            var chunk = [UInt8](repeating: 0, count: inflateChunkBytes)

            while true {
                let status = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                try require(produced <= expectedSize - output.count,
                            "An Android AAR DEFLATE stream exceeds its declared size: \(name).")
                output.append(contentsOf: chunk.prefix(produced))

                if status == Z_STREAM_END {
                    break
                }
                try require(status == Z_OK,
                            "The Android AAR contains an invalid or truncated DEFLATE stream: \(name).")
                try require(produced > 0 || stream.avail_in > 0,
                            "The Android AAR DEFLATE stream made no progress: \(name).")
            }

            try require(stream.avail_in == 0,
                        "The Android AAR DEFLATE stream contains trailing compressed data: \(name).")
        }
        try require(output.count == expectedSize,
                    "The Android AAR DEFLATE stream does not match its declared size: \(name).")
        return output
    }

    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var remainder = UInt32(value)
        for _ in 0..<8 {
            remainder = remainder & 1 == 0 ? remainder >> 1 : (remainder >> 1) ^ 0xEDB8_8320
        }
        return remainder
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum = UInt32.max
        for byte in data {
            let index = Int((checksum ^ UInt32(byte)) & 0xFF)
            checksum = (checksum >> 8) ^ crc32Table[index]
        }
        return checksum ^ UInt32.max
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ElementCallCandidateError.validation(message) }
    }
}
