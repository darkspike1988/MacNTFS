import XCTest
@testable import NTFSCore

final class LinkTests: XCTestCase {

    private func le(_ value: UInt64, _ bytes: Int) -> [UInt8] {
        (0..<bytes).map { UInt8((value >> UInt64(8 * $0)) & 0xFF) }
    }

    private func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { le(UInt64($0), 2) }
    }

    /// A reparse data buffer for a symbolic link (flags present) or a junction (no flags).
    private func windowsLink(tag: UInt32, substitute: String, printed: String, flags: UInt32 = 0) -> Data {
        let sub = utf16(substitute)
        let pri = utf16(printed)
        var body = le(0, 2) + le(UInt64(sub.count), 2) + le(UInt64(sub.count), 2) + le(UInt64(pri.count), 2)
        if tag == 0xA000_000C { body += le(UInt64(flags), 4) }
        body += sub + pri
        return Data(le(UInt64(tag), 4) + le(UInt64(body.count), 2) + le(0, 2) + body)
    }

    func testSymlinkJunctionAndRelativeFlag() throws {
        let symlink = try LinkParser.parseReparsePoint(windowsLink(tag: 0xA000_000C, substitute: "..\\a", printed: "..\\a", flags: 1))
        XCTAssertEqual(symlink.kind, .symlink)
        XCTAssertEqual(symlink.target, "..\\a")
        XCTAssertTrue(symlink.isRelative)

        let junction = try LinkParser.parseReparsePoint(windowsLink(tag: 0xA000_0003, substitute: "\\??\\C:\\x", printed: "C:\\x"))
        XCTAssertEqual(junction.kind, .junction)
        XCTAssertEqual(junction.substituteName, "\\??\\C:\\x")
        XCTAssertEqual(junction.target, "C:\\x")
        XCTAssertFalse(junction.isRelative, "only a symbolic link can be relative")
    }

    func testWSLLinkAndUnknownTag() throws {
        let target = Array("/usr/bin/env".utf8)
        let wsl = Data(le(0xA000_001D, 4) + le(UInt64(4 + target.count), 2) + le(0, 2) + le(2, 4) + target)
        let link = try LinkParser.parseReparsePoint(wsl)
        XCTAssertEqual(link.kind, .wslSymlink)
        XCTAssertEqual(link.target, "/usr/bin/env")

        let cloud = Data(le(0x9000_001A, 4) + le(0, 2) + le(0, 2))
        XCTAssertEqual(try LinkParser.parseReparsePoint(cloud).kind, .other(tag: 0x9000_001A))
    }

    func testDamagedReparseDataIsRejected() {
        var tooShort = windowsLink(tag: 0xA000_000C, substitute: "abc", printed: "abc", flags: 1)
        tooShort.removeLast(4)
        XCTAssertThrowsError(try LinkParser.parseReparsePoint(tooShort), "the data is shorter than its length field says")

        var oddLength = windowsLink(tag: 0xA000_000C, substitute: "abc", printed: "abc", flags: 1)
        oddLength[10] = 3  // substitute name length: not a multiple of 2
        XCTAssertThrowsError(try LinkParser.parseReparsePoint(oddLength))

        var pastTheEnd = windowsLink(tag: 0xA000_0003, substitute: "abc", printed: "abc")
        pastTheEnd[8] = 0x80  // substitute name offset far outside the buffer
        XCTAssertThrowsError(try LinkParser.parseReparsePoint(pastTheEnd))

        XCTAssertThrowsError(try LinkParser.parseReparsePoint(Data([0x0C, 0x00])), "not even a header")
    }

    func testInteixLink() {
        let payload = Data(Array("IntxLNK".utf8) + [0x01] + utf16("../a/b"))
        let link = LinkParser.parseInterixLink(payload)
        XCTAssertEqual(link?.kind, .interixSymlink)
        XCTAssertEqual(link?.target, "../a/b")

        XCTAssertNil(LinkParser.parseInterixLink(Data("not a link at all".utf8)))
        XCTAssertNil(LinkParser.parseInterixLink(Data(Array("IntxLNK".utf8) + [0x01, 0x41])), "odd number of bytes is no UTF-16")
        XCTAssertNil(LinkParser.parseInterixLink(Data()))
    }
}
