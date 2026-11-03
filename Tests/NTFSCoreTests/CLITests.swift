import XCTest
@testable import NTFSCore

/// Runs the built `macntfs` binary against the committed mini image. Build it first with `swift build`.
final class CLITests: XCTestCase {

    private struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private var binary: URL {
        Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("macntfs")
    }

    private var mini: String {
        Fixtures.directory.appendingPathComponent("mini.img").path
    }

    private func run(_ arguments: [String]) throws -> Result {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "macntfs is not built; run swift build first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func temporaryImage(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macntfs-cli-\(UUID().uuidString).img")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    // MARK: - Reading

    func testListCatAndStreams() throws {
        let list = try run(["ls", mini, "/"])
        XCTAssertEqual(list.status, 0)
        XCTAssertTrue(String(decoding: list.stdout, as: UTF8.self).contains("small.txt"))

        let cat = try run(["cat", mini, "/small.txt"])
        XCTAssertEqual(cat.status, 0)
        XCTAssertEqual(cat.stdout, Data("hello".utf8))
        XCTAssertEqual(cat.stderr, "", "a normal read prints nothing on standard error")

        let streams = try run(["streams", mini, "/small.txt"])
        XCTAssertEqual(streams.status, 0)
        XCTAssertTrue(String(decoding: streams.stdout, as: UTF8.self).contains("(default)"))
    }

    func testProbeShowsTheVolumeState() throws {
        let probe = try run(["probe", mini])
        XCTAssertEqual(probe.status, 0)
        let text = String(decoding: probe.stdout, as: UTF8.self)
        XCTAssertTrue(text.contains("Volume name:         MINI"))
        XCTAssertTrue(text.contains("Dirty flag:          clear"))
        XCTAssertTrue(text.contains("Hibernation:         no hiberfil.sys"))
        XCTAssertTrue(text.contains("Mounted:             no"))
    }

    func testLargeFileIsStreamedInBlocksWithoutChanges() throws {
        let cat = try run(["cat", mini, "/big.bin"])
        XCTAssertEqual(cat.status, 0)
        let expected = try NTFSVolume(blockDevice: MemoryBlockDevice(data: try Fixtures.miniImage())).readFile(at: "/big.bin")
        XCTAssertEqual(cat.stdout, expected)
    }

    func testAllowMountedIsAcceptedForImages() throws {
        XCTAssertEqual(try run(["ls", mini, "/", "--allow-mounted"]).status, 0)
    }

    // MARK: - Exit codes and channels

    func testUsageErrorsExitWith2() throws {
        XCTAssertEqual(try run([]).status, 2)
        let unknown = try run(["frobnicate"])
        XCTAssertEqual(unknown.status, 2)
        XCTAssertTrue(unknown.stderr.contains("Unknown command"))
        XCTAssertEqual(try run(["cat", mini]).status, 2, "missing file argument")
        XCTAssertEqual(try run(["cat", mini, "/small.txt", "--stream"]).status, 2, "--stream needs a name")
    }

    func testCommandsThatWouldWriteDoNotExist() throws {
        for command in ["format", "write", "create-image", "repair", "check"] {
            let result = try run([command, mini])
            XCTAssertEqual(result.status, 2, "'\(command)' must be an unknown command")
            XCTAssertEqual(result.stdout.count, 0)
        }
    }

    func testErrorsGoToStandardErrorOnly() throws {
        let missing = try run(["cat", mini, "/does-not-exist"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.stdout.count, 0, "an error must not end up in redirected output")
        XCTAssertTrue(missing.stderr.contains("not found"))

        let directory = try run(["cat", mini, "/dir"])
        XCTAssertEqual(directory.status, 1)
        XCTAssertEqual(directory.stdout.count, 0)

        let notALink = try run(["readlink", mini, "/small.txt"])
        XCTAssertEqual(notALink.status, 1)
        XCTAssertTrue(notALink.stderr.contains("not a link"))

        let noStream = try run(["cat", mini, "/small.txt", "--stream", "nope"])
        XCTAssertEqual(noStream.status, 1)
        XCTAssertEqual(noStream.stdout.count, 0)
    }

    func testUnsupportedFeatureExitsWith3() throws {
        // An encrypted flag on the data attribute of /big.bin.
        let image = try Fixtures.patchedImage(try Fixtures.miniImage(), path: "/big.bin") { image, record, _, data in
            image[record + data + 13] |= 0x40
        }
        let path = try temporaryImage(image)
        let result = try run(["cat", path, "/big.bin"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout.count, 0)
        XCTAssertTrue(result.stderr.contains("encryption"))
    }

    // MARK: - Warnings

    func testDirtyVolumeIsReportedOnStandardError() throws {
        // Set bit 0 of the volume flags in $VOLUME_INFORMATION (flags at value offset 10).
        let image = try Fixtures.patchedImage(try Fixtures.miniImage(), path: "/$Volume") { image, record, _, _ in
            let attribute = Fixtures.attributeOffset(type: 0x70, in: image, recordOffset: record)!
            let valueOffset = Int(image[record + attribute + 0x14]) | (Int(image[record + attribute + 0x15]) << 8)
            image[record + attribute + valueOffset + 10] |= 0x01
        }
        let path = try temporaryImage(image)

        let ls = try run(["ls", path, "/"])
        XCTAssertEqual(ls.status, 0, "a dirty volume is still read")
        XCTAssertTrue(ls.stderr.contains("not shut down cleanly"))
        XCTAssertTrue(String(decoding: try run(["probe", path]).stdout, as: UTF8.self).contains("Dirty flag:          SET"))
    }

    func testUnreadableVolumeFlagsAreReported() throws {
        let image = try Fixtures.patchedImage(try Fixtures.miniImage(), path: "/$Volume") { image, record, _, _ in
            image.replaceSubrange(record..<(record + 4), with: Data("XXXX".utf8))
        }
        let path = try temporaryImage(image)
        let ls = try run(["ls", path, "/"])
        XCTAssertEqual(ls.status, 0)
        XCTAssertTrue(ls.stderr.contains("could not be read"), "an unreadable $Volume must not look like a clean volume")
    }
}
