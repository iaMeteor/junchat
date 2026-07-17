/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import CryptoKit
import Foundation
@testable import Tools
import XCTest
import zlib

final class ElementCallCandidateAARTests: XCTestCase {
    func testVerifiesStoredFixture() throws {
        let index = Data("<html>stored</html>".utf8)
        let script = Data("console.log('stored')".utf8)
        let fixture = try makeFixture([
            .init(name: "AndroidManifest.xml", contents: Data("<manifest/>".utf8), method: 0),
            .init(name: "assets/element-call/index.html", contents: index, method: 0),
            .init(name: "assets/element-call/assets/app.js", contents: script, method: 0)
        ])

        XCTAssertNoThrow(try ElementCallCandidateAAR.verify(fixture.data,
                                                            expectedEmbeddedFiles: [
                                                                expectedFile(path: "index.html", contents: index),
                                                                expectedFile(path: "assets/app.js", contents: script)
                                                            ]))
    }

    func testVerifiesDeflatedFixtureWithDirectoryAndDataDescriptor() throws {
        let index = Data(String(repeating: "element-call-", count: 128).utf8)
        let fixture = try makeFixture([
            .init(name: "assets/", contents: Data(), method: 8, externalAttributes: directoryAttributes),
            .init(name: "assets/element-call/", contents: Data(), method: 8, externalAttributes: directoryAttributes),
            .init(name: "assets/element-call/index.html", contents: index, method: 8, usesDataDescriptor: true)
        ])

        XCTAssertNoThrow(try ElementCallCandidateAAR.verify(fixture.data,
                                                            expectedEmbeddedFiles: [expectedFile(path: "index.html",
                                                                                                 contents: index)]))
    }

    func testRejectsTamperedPayload() throws {
        let contents = Data("untampered".utf8)
        var fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: contents, method: 0)
        ])
        fixture.data[fixture.layouts[0].dataOffset] ^= 0x01

        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data,
                                                                expectedEmbeddedFiles: [expectedFile(path: "index.html",
                                                                                                     contents: contents)]))
    }

    func testRejectsDuplicateEntryNames() throws {
        let first = Data("one".utf8)
        let fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: first, method: 0),
            .init(name: "assets/element-call/index.html", contents: Data("two".utf8), method: 0)
        ])

        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data,
                                                                expectedEmbeddedFiles: [expectedFile(path: "index.html",
                                                                                                     contents: first)])) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate ZIP entry"))
        }
    }

    func testRejectsTraversalAndNoncanonicalEntryPaths() throws {
        for path in [
            "assets/element-call/../escape.js",
            "assets//element-call/index.html",
            "/assets/element-call/index.html",
            "assets\\element-call\\index.html"
        ] {
            let fixture = try makeFixture([.init(name: path, contents: Data(), method: 0)])
            XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data, expectedEmbeddedFiles: []),
                                 "Expected rejection for \(path)")
        }
    }

    func testRejectsSymlinkAndUnsupportedUnixEntryTypes() throws {
        let contents = Data("target".utf8)
        for (attributes, message) in [(UInt32(0o120777) << 16, "symbolic link"),
                                      (UInt32(0o010644) << 16, "Unix entry type")] {
            let fixture = try makeFixture([
                .init(name: "assets/element-call/index.html",
                      contents: contents,
                      method: 0,
                      externalAttributes: attributes)
            ])
            XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data,
                                                                    expectedEmbeddedFiles: [expectedFile(path: "index.html",
                                                                                                         contents: contents)])) { error in
                XCTAssertTrue(error.localizedDescription.contains(message))
            }
        }
    }

    func testRejectsMissingAndExtraEmbeddedFiles() throws {
        let index = Data("index".utf8)
        let fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: index, method: 0)
        ])

        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data,
                                                                expectedEmbeddedFiles: [
                                                                    expectedFile(path: "index.html", contents: index),
                                                                    expectedFile(path: "missing.js", contents: Data("missing".utf8))
                                                                ]))

        let extraFixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: index, method: 0),
            .init(name: "assets/element-call/extra.js", contents: Data("extra".utf8), method: 0)
        ])
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(extraFixture.data,
                                                                expectedEmbeddedFiles: [expectedFile(path: "index.html",
                                                                                                     contents: index)]))
    }

    func testRejectsMismatchedEmbeddedFileDigestAndSize() throws {
        let contents = Data("verified bytes".utf8)
        let fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: contents, method: 0)
        ])
        let valid = expectedFile(path: "index.html", contents: contents)

        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data,
                                                                expectedEmbeddedFiles: [
                                                                    .init(path: valid.path,
                                                                          sha256: String(repeating: "0", count: 64),
                                                                          size: valid.size)
                                                                ]))
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data,
                                                                expectedEmbeddedFiles: [
                                                                    .init(path: valid.path,
                                                                          sha256: valid.sha256,
                                                                          size: valid.size + 1)
                                                                ]))
    }

    func testRejectsInvalidCRCAndDeclaredSizeForAnyRegularEntry() throws {
        let contents = Data(String(repeating: "manifest", count: 20).utf8)
        var crcFixture = try makeFixture([
            .init(name: "AndroidManifest.xml", contents: contents, method: 8)
        ])
        let incorrectCRC = fixtureCRC32(contents) ^ 1
        write(incorrectCRC, at: crcFixture.layouts[0].localHeaderOffset + 14, in: &crcFixture.data)
        write(incorrectCRC, at: crcFixture.layouts[0].centralHeaderOffset + 16, in: &crcFixture.data)
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(crcFixture.data, expectedEmbeddedFiles: []))

        var sizeFixture = try makeFixture([
            .init(name: "AndroidManifest.xml", contents: contents, method: 8)
        ])
        let incorrectSize = UInt32(contents.count + 1)
        write(incorrectSize, at: sizeFixture.layouts[0].localHeaderOffset + 22, in: &sizeFixture.data)
        write(incorrectSize, at: sizeFixture.layouts[0].centralHeaderOffset + 24, in: &sizeFixture.data)
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(sizeFixture.data, expectedEmbeddedFiles: []))
    }

    func testRejectsUnsupportedCompressionMethod() throws {
        var fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: Data("index".utf8), method: 0)
        ])
        write(UInt16(12), at: fixture.layouts[0].localHeaderOffset + 8, in: &fixture.data)
        write(UInt16(12), at: fixture.layouts[0].centralHeaderOffset + 10, in: &fixture.data)

        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(fixture.data, expectedEmbeddedFiles: []))
    }

    func testRejectsTruncationAtLocalCentralAndEndRecords() throws {
        let fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: Data("index".utf8), method: 8)
        ])
        let cutOffsets = [
            fixture.layouts[0].dataOffset,
            fixture.centralOffset + 20,
            fixture.endRecordOffset + 10,
            fixture.data.count - 1
        ]

        for cutOffset in cutOffsets {
            let truncated = Data(fixture.data.prefix(cutOffset))
            XCTAssertThrowsError(try ElementCallCandidateAAR.verify(truncated, expectedEmbeddedFiles: []),
                                 "Expected rejection when truncated at byte \(cutOffset)")
        }
    }

    func testRejectsMalformedLocalCentralAndEndRecordSignatures() throws {
        let fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: Data("index".utf8), method: 0)
        ])
        for offset in [fixture.layouts[0].localHeaderOffset,
                       fixture.layouts[0].centralHeaderOffset,
                       fixture.endRecordOffset] {
            var malformed = fixture.data
            write(UInt32(0), at: offset, in: &malformed)
            XCTAssertThrowsError(try ElementCallCandidateAAR.verify(malformed, expectedEmbeddedFiles: []))
        }
    }

    func testRejectsEncryptionMultiDiskAndZIP64Markers() throws {
        let contents = Data("index".utf8)
        let fixture = try makeFixture([
            .init(name: "assets/element-call/index.html", contents: contents, method: 0)
        ])
        let expected = [expectedFile(path: "index.html", contents: contents)]

        var encrypted = fixture.data
        write(UInt16(0x0801), at: fixture.layouts[0].localHeaderOffset + 6, in: &encrypted)
        write(UInt16(0x0801), at: fixture.layouts[0].centralHeaderOffset + 8, in: &encrypted)
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(encrypted, expectedEmbeddedFiles: expected)) { error in
            XCTAssertTrue(error.localizedDescription.contains("encrypted ZIP entry"))
        }

        var multiDisk = fixture.data
        write(UInt16(1), at: fixture.endRecordOffset + 4, in: &multiDisk)
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(multiDisk, expectedEmbeddedFiles: expected)) { error in
            XCTAssertTrue(error.localizedDescription.contains("multi-disk"))
        }

        var zip64 = fixture.data
        write(UInt16.max, at: fixture.endRecordOffset + 8, in: &zip64)
        write(UInt16.max, at: fixture.endRecordOffset + 10, in: &zip64)
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(zip64, expectedEmbeddedFiles: expected)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ZIP64"))
        }
    }

    func testRejectsOverlappingAndOutOfBoundsLocalData() throws {
        var overlapping = try makeFixture([
            .init(name: "first.bin", contents: Data("first".utf8), method: 0),
            .init(name: "second.bin", contents: Data("second".utf8), method: 0)
        ])
        let overlappingSize = UInt32(overlapping.layouts[0].uncompressedSize + 4)
        write(overlappingSize, at: overlapping.layouts[0].localHeaderOffset + 18, in: &overlapping.data)
        write(overlappingSize, at: overlapping.layouts[0].localHeaderOffset + 22, in: &overlapping.data)
        write(overlappingSize, at: overlapping.layouts[0].centralHeaderOffset + 20, in: &overlapping.data)
        write(overlappingSize, at: overlapping.layouts[0].centralHeaderOffset + 24, in: &overlapping.data)
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(overlapping.data, expectedEmbeddedFiles: []))

        var outOfBounds = try makeFixture([
            .init(name: "index.html", contents: Data("index".utf8), method: 0)
        ])
        write(UInt32(outOfBounds.centralOffset),
              at: outOfBounds.layouts[0].centralHeaderOffset + 42,
              in: &outOfBounds.data)
        XCTAssertThrowsError(try ElementCallCandidateAAR.verify(outOfBounds.data, expectedEmbeddedFiles: []))
    }

    private let directoryAttributes = (UInt32(0o040755) << 16) | 0x10

    private struct FixtureEntry {
        let name: String
        let contents: Data
        let method: UInt16
        let externalAttributes: UInt32
        let usesDataDescriptor: Bool

        init(name: String,
             contents: Data,
             method: UInt16,
             externalAttributes: UInt32 = UInt32(0o100644) << 16,
             usesDataDescriptor: Bool = false) {
            self.name = name
            self.contents = contents
            self.method = method
            self.externalAttributes = externalAttributes
            self.usesDataDescriptor = usesDataDescriptor
        }
    }

    private struct FixtureLayout {
        let localHeaderOffset: Int
        let dataOffset: Int
        let centralHeaderOffset: Int
        let uncompressedSize: Int
    }

    private struct Fixture {
        var data: Data
        let layouts: [FixtureLayout]
        let centralOffset: Int
        let endRecordOffset: Int
    }

    private struct PendingEntry {
        let entry: FixtureEntry
        let name: Data
        let compressed: Data
        let checksum: UInt32
        let flags: UInt16
        let versionNeeded: UInt16
        let localHeaderOffset: Int
        let dataOffset: Int
    }

    private enum FixtureError: Error {
        case compressionFailed
    }

    private func makeFixture(_ entries: [FixtureEntry]) throws -> Fixture {
        var data = Data()
        var pendingEntries = [PendingEntry]()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let compressed = entry.method == 8 ? try rawDeflate(entry.contents) : entry.contents
            let checksum = fixtureCRC32(entry.contents)
            let flags: UInt16 = entry.usesDataDescriptor ? 0x0808 : 0x0800
            let versionNeeded: UInt16 = entry.method == 0 ? 10 : 20
            let localHeaderOffset = data.count

            append(UInt32(0x0403_4B50), to: &data)
            append(versionNeeded, to: &data)
            append(flags, to: &data)
            append(entry.method, to: &data)
            append(UInt16(0), to: &data)
            append(UInt16(0), to: &data)
            append(entry.usesDataDescriptor ? UInt32(0) : checksum, to: &data)
            append(entry.usesDataDescriptor ? UInt32(0) : UInt32(compressed.count), to: &data)
            append(entry.usesDataDescriptor ? UInt32(0) : UInt32(entry.contents.count), to: &data)
            append(UInt16(name.count), to: &data)
            append(UInt16(0), to: &data)
            data.append(name)
            let dataOffset = data.count
            data.append(compressed)
            if entry.usesDataDescriptor {
                append(UInt32(0x0807_4B50), to: &data)
                append(checksum, to: &data)
                append(UInt32(compressed.count), to: &data)
                append(UInt32(entry.contents.count), to: &data)
            }

            pendingEntries.append(PendingEntry(entry: entry,
                                               name: name,
                                               compressed: compressed,
                                               checksum: checksum,
                                               flags: flags,
                                               versionNeeded: versionNeeded,
                                               localHeaderOffset: localHeaderOffset,
                                               dataOffset: dataOffset))
        }

        let centralOffset = data.count
        var layouts = [FixtureLayout]()
        for pending in pendingEntries {
            let centralHeaderOffset = data.count
            append(UInt32(0x0201_4B50), to: &data)
            append(UInt16(0x0314), to: &data)
            append(pending.versionNeeded, to: &data)
            append(pending.flags, to: &data)
            append(pending.entry.method, to: &data)
            append(UInt16(0), to: &data)
            append(UInt16(0), to: &data)
            append(pending.checksum, to: &data)
            append(UInt32(pending.compressed.count), to: &data)
            append(UInt32(pending.entry.contents.count), to: &data)
            append(UInt16(pending.name.count), to: &data)
            append(UInt16(0), to: &data)
            append(UInt16(0), to: &data)
            append(UInt16(0), to: &data)
            append(UInt16(0), to: &data)
            append(pending.entry.externalAttributes, to: &data)
            append(UInt32(pending.localHeaderOffset), to: &data)
            data.append(pending.name)
            layouts.append(FixtureLayout(localHeaderOffset: pending.localHeaderOffset,
                                         dataOffset: pending.dataOffset,
                                         centralHeaderOffset: centralHeaderOffset,
                                         uncompressedSize: pending.entry.contents.count))
        }

        let endRecordOffset = data.count
        append(UInt32(0x0605_4B50), to: &data)
        append(UInt16(0), to: &data)
        append(UInt16(0), to: &data)
        append(UInt16(entries.count), to: &data)
        append(UInt16(entries.count), to: &data)
        append(UInt32(endRecordOffset - centralOffset), to: &data)
        append(UInt32(centralOffset), to: &data)
        append(UInt16(0), to: &data)
        return Fixture(data: data,
                       layouts: layouts,
                       centralOffset: centralOffset,
                       endRecordOffset: endRecordOffset)
    }

    private func rawDeflate(_ contents: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream,
                            Z_DEFAULT_COMPRESSION,
                            Z_DEFLATED,
                            -MAX_WBITS,
                            8,
                            Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw FixtureError.compressionFailed
        }
        defer { deflateEnd(&stream) }

        var output = [UInt8](repeating: 0, count: max(64, Int(deflateBound(&stream, uLong(contents.count)))))
        let status = contents.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer -> Int32 in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw FixtureError.compressionFailed }
        return Data(output.prefix(output.count - Int(stream.avail_out)))
    }

    private func expectedFile(path: String, contents: Data) -> ElementCallCandidateAARExpectedFile {
        .init(path: path, sha256: sha256(contents), size: Int64(contents.count))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixtureCRC32(_ data: Data) -> UInt32 {
        UInt32(data.withUnsafeBytes { buffer in
            crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
        })
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func write(_ value: UInt16, at offset: Int, in data: inout Data) {
        for index in 0..<2 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt16(index * 8))
        }
    }

    private func write(_ value: UInt32, at offset: Int, in data: inout Data) {
        for index in 0..<4 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }
}
