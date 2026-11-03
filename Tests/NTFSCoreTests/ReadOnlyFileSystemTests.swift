import XCTest
@testable import NTFSCore

final class ReadOnlyFileSystemTests: XCTestCase {
    private func makeFileSystem(capacity: Int = 4096) throws -> ReadOnlyFileSystem {
        var options = ReadOnlyFileSystem.Options()
        options.recordCacheCapacity = capacity
        let volume = try NTFSVolume(blockDevice: MemoryBlockDevice(data: Fixtures.miniImage()))
        return ReadOnlyFileSystem(volume: volume, options: options)
    }

    func testRootListsUserFilesAndHidesMetadataFiles() throws {
        let fs = try makeFileSystem()
        let page = try fs.contents(ofDirectory: ReadOnlyFileSystem.rootID)
        let names = Set(page.items.map(\.name))
        XCTAssertEqual(names, ["big.bin", "dir", "empty.bin", "many", "small.txt", "unicode"])
        XCTAssertNil(page.next)
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix("$") })
    }

    func testLookupDescribeAndReadMatchThePathBasedApi() throws {
        let fs = try makeFileSystem()
        let big = try fs.lookup(name: "big.bin", inDirectory: ReadOnlyFileSystem.rootID)
        XCTAssertEqual(big.kind, .file)
        XCTAssertEqual(big.size, 20000)
        XCTAssertEqual(big.allocatedSize % 4096, 0)
        XCTAssertGreaterThanOrEqual(big.allocatedSize, 20000)
        XCTAssertEqual(try fs.item(id: big.id), big)
        let data = try fs.read(id: big.id, offset: 0, length: 20000)
        XCTAssertEqual(data, try fs.volume.readFile(at: "/big.bin"))
        // A read in the middle and a read past the end.
        XCTAssertEqual(try fs.read(id: big.id, offset: 100, length: 50), data.subdata(in: 100..<150))
        XCTAssertEqual(try fs.read(id: big.id, offset: 19990, length: 100).count, 10)
        XCTAssertEqual(try fs.read(id: big.id, offset: 30000, length: 10).count, 0)
    }

    func testNameLookupIgnoresCase() throws {
        let fs = try makeFileSystem()
        let upper = try fs.lookup(name: "BIG.BIN", inDirectory: ReadOnlyFileSystem.rootID)
        XCTAssertEqual(upper.id, try fs.lookup(name: "big.bin", inDirectory: ReadOnlyFileSystem.rootID).id)
    }

    func testDirectoryPagesCoverEveryEntryOnceInOrder() throws {
        let fs = try makeFileSystem()
        let many = try fs.lookup(name: "many", inDirectory: ReadOnlyFileSystem.rootID)
        XCTAssertEqual(many.kind, .directory)
        var names = [String](), position = 0, pages = 0
        while true {
            let page = try fs.contents(ofDirectory: many.id, from: position, count: 7)
            names += page.items.map(\.name)
            pages += 1
            guard let next = page.next else { break }
            XCTAssertGreaterThan(next, position)
            position = next
        }
        XCTAssertEqual(names.count, 150)
        XCTAssertEqual(Set(names).count, 150, "no entry twice")
        XCTAssertEqual(pages, 22)
        XCTAssertEqual(names, try fs.volume.listDirectory(recordNumber: many.id).map(\.name))
    }

    func testRecordCacheIsBoundedAndDoesNotChangeResults() throws {
        let small = try makeFileSystem(capacity: 4)
        let off = try makeFileSystem(capacity: 0)
        let many = try small.lookup(name: "many", inDirectory: ReadOnlyFileSystem.rootID)
        let first = try small.contents(ofDirectory: many.id, from: 0, count: 150)
        XCTAssertLessThanOrEqual(small.cachedRecordCount, 4)
        let manyOff = try off.lookup(name: "many", inDirectory: ReadOnlyFileSystem.rootID)
        let second = try off.contents(ofDirectory: manyOff.id, from: 0, count: 150)
        XCTAssertEqual(off.cachedRecordCount, 0)
        XCTAssertEqual(first.items.map(\.name), second.items.map(\.name))
        XCTAssertEqual(first.items.map(\.item), second.items.map(\.item))
        small.purgeCaches()
        XCTAssertEqual(small.cachedRecordCount, 0)
    }

    func testEveryWriteIsRefusedWithEROFS() throws {
        let fs = try makeFileSystem()
        let big = try fs.lookup(name: "big.bin", inDirectory: ReadOnlyFileSystem.rootID)
        func expectReadOnly(_ operation: () throws -> Never, file: StaticString = #filePath, line: UInt = #line) {
            do { try operation(); XCTFail("must not succeed", file: file, line: line) } catch let error as FileSystemError {
                XCTAssertEqual(error, .readOnly, file: file, line: line)
                XCTAssertEqual(error.posixCode, EROFS, file: file, line: line)
            } catch { XCTFail("wrong error \(error)", file: file, line: line) }
        }
        expectReadOnly { try fs.write(id: big.id, offset: 0, data: Data([1])) }
        expectReadOnly { try fs.setSize(id: big.id, size: 0) }
        expectReadOnly { try fs.createItem(named: "x", inDirectory: ReadOnlyFileSystem.rootID, kind: .file) }
        expectReadOnly { try fs.removeItem(named: "big.bin", inDirectory: ReadOnlyFileSystem.rootID) }
        expectReadOnly { try fs.renameItem(named: "big.bin", inDirectory: ReadOnlyFileSystem.rootID, to: "y", inDirectory: ReadOnlyFileSystem.rootID) }
        // The volume is as it was.
        XCTAssertEqual(try fs.read(id: big.id, offset: 0, length: 20000), try fs.volume.readFile(at: "/big.bin"))
    }

    func testErrorsMapToPosixCodes() throws {
        let fs = try makeFileSystem()
        let root = ReadOnlyFileSystem.rootID
        func code(_ operation: () throws -> Any) -> Int32? {
            do { _ = try operation(); return nil } catch let error as FileSystemError { return error.posixCode } catch { return -1 }
        }
        XCTAssertEqual(code { try fs.lookup(name: "missing", inDirectory: root) }, ENOENT)
        XCTAssertEqual(code { try fs.lookup(name: "x", inDirectory: try fs.lookup(name: "big.bin", inDirectory: root).id) }, ENOTDIR)
        XCTAssertEqual(code { try fs.contents(ofDirectory: try fs.lookup(name: "big.bin", inDirectory: root).id) }, ENOTDIR)
        XCTAssertEqual(code { try fs.read(id: try fs.lookup(name: "dir", inDirectory: root).id, offset: 0, length: 10) }, EISDIR)
        XCTAssertEqual(code { try fs.contents(ofDirectory: root, from: -1, count: 10) }, EINVAL)
        XCTAssertNotNil(code { try fs.item(id: 99_999_999) })
        // Metadata files are not reachable by name.
        XCTAssertEqual(code { try fs.lookup(name: "$MFT", inDirectory: root) }, ENOENT)
    }

    func testLinksAreReportedAndNotFollowed() throws {
        let image = try Fixtures.windowsImage("links")
        let fs = ReadOnlyFileSystem(volume: try NTFSVolume(blockDevice: MemoryBlockDevice(data: image)))
        let links = try fs.lookup(name: "links", inDirectory: ReadOnlyFileSystem.rootID)
        let sym = try fs.lookup(name: "sym-rel", inDirectory: links.id)
        XCTAssertEqual(sym.kind, .symlink)
        XCTAssertEqual(try fs.readLink(id: sym.id)?.target, "target.txt")
        XCTAssertEqual(try fs.readLink(id: sym.id)?.isRelative, true)
        let junction = try fs.lookup(name: "junction", inDirectory: links.id)
        XCTAssertEqual(junction.kind, .symlink)
        XCTAssertEqual(try fs.readLink(id: junction.id)?.kind, .junction)
        // The content of a link is not read, and a link is not listed as a directory.
        XCTAssertThrowsError(try fs.read(id: sym.id, offset: 0, length: 10)) { XCTAssertEqual($0 as? FileSystemError, .unsupported("reparse")) }
        // A hard link is a file with a link count of 2.
        let hard = try fs.lookup(name: "hard", inDirectory: links.id)
        XCTAssertEqual(hard.kind, .file)
        XCTAssertEqual(hard.linkCount, 2)
        XCTAssertEqual(hard.id, try fs.lookup(name: "target.txt", inDirectory: links.id).id)
        XCTAssertNil(try fs.readLink(id: hard.id))
    }

    func testStreamNamesAndStreamReads() throws {
        let image = try Fixtures.windowsImage("ads")
        let fs = ReadOnlyFileSystem(volume: try NTFSVolume(blockDevice: MemoryBlockDevice(data: image)))
        let directory = try fs.lookup(name: "ads", inDirectory: ReadOnlyFileSystem.rootID)
        let file = try fs.lookup(name: "small.txt", inDirectory: directory.id)
        XCTAssertEqual(Set(try fs.streamNames(id: file.id)), ["s1", "s2"])
        XCTAssertEqual(try fs.read(id: file.id, stream: "s1", offset: 0, length: 100), Data("one".utf8))
    }

    func testParentIDsPointToTheDirectory() throws {
        let fs = try makeFileSystem()
        let dir = try fs.lookup(name: "dir", inDirectory: ReadOnlyFileSystem.rootID)
        let nested = try fs.lookup(name: "nested.txt", inDirectory: dir.id)
        XCTAssertEqual(nested.parentID, dir.id)
        XCTAssertEqual(dir.parentID, ReadOnlyFileSystem.rootID)
        XCTAssertEqual(try fs.item(id: ReadOnlyFileSystem.rootID).parentID, ReadOnlyFileSystem.rootID)
    }

    func testExactSpellingWinsWhenTwoNamesDifferOnlyInNormalization() throws {
        // mini.img holds two different files, one named in NFC and one in NFD.
        let fs = try makeFileSystem()
        let folder = try fs.lookup(name: "unicode", inDirectory: ReadOnlyFileSystem.rootID)
        let page = try fs.contents(ofDirectory: folder.id)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(Set(page.items.map(\.item.id)).count, 2)
        for entry in page.items {
            XCTAssertEqual(try fs.lookup(name: entry.name, inDirectory: folder.id).id, entry.item.id)
        }
    }

    func testLookupFindsAnotherUnicodeSpellingOfTheSameName() throws {
        // win-basic.img (written by Windows) has one file "Grüße-äöü.txt".
        let image = try Fixtures.windowsImage("basic")
        let fs = ReadOnlyFileSystem(volume: try NTFSVolume(blockDevice: MemoryBlockDevice(data: image)))
        let folder = try fs.lookup(name: "uni", inDirectory: ReadOnlyFileSystem.rootID)
        let stored = try fs.contents(ofDirectory: folder.id).items.map(\.name).first { $0.hasPrefix("Gr") }
        let name = try XCTUnwrap(stored)
        let composed = name.precomposedStringWithCanonicalMapping
        let decomposed = name.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let expected = try fs.lookup(name: name, inDirectory: folder.id).id
        XCTAssertEqual(try fs.lookup(name: composed, inDirectory: folder.id).id, expected)
        XCTAssertEqual(try fs.lookup(name: decomposed, inDirectory: folder.id).id, expected)
        XCTAssertEqual(ReadOnlyFileSystem.nameCandidates("e\u{301}").count, 2)
        XCTAssertEqual(ReadOnlyFileSystem.nameCandidates("plain").count, 1)
    }

    func testWindowsLinkTargetsBecomePosixPaths() {
        func link(_ substitute: String, _ printed: String) -> LinkInfo {
            LinkInfo(kind: .symlink, substituteName: substitute, printName: printed, flags: 0)
        }
        XCTAssertEqual(link("dir\\sub\\file.txt", "dir\\sub\\file.txt").posixTarget, "dir/sub/file.txt")
        XCTAssertEqual(link("\\??\\C:\\target", "").posixTarget, "C:/target")
        XCTAssertEqual(link("x", "..\\up").posixTarget, "../up")
    }
}
