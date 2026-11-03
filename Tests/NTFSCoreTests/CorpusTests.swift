import XCTest
import CryptoKit
@testable import NTFSCore

/// Compares the engine with the reference corpus built by scripts/corpus/build.sh.
/// The truth is the manifest: hashes of the source content, computed before it went into the image.
/// For every entry the engine must return the same bytes or refuse with the expected `unsupported` error.
/// Wrong bytes without an error are always a failure.
final class CorpusTests: XCTestCase {

    private struct Stream: Decodable {
        let name: String
        let size: UInt64
        let sha256: String
    }

    private struct Entry: Decodable {
        let path: String
        let type: String
        let size: UInt64?
        let sha256: String?
        let expect: String?
        let streams: [Stream]?
    }

    private struct Manifest: Decodable {
        let schema: Int
        let image: String
        let entries: [Entry]
    }

    /// The built corpus (not committed) and the committed fixtures.
    private static var manifestDirectories: [URL] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // MACNTFS_CORPUS_DIR points the test at another directory with built images.
        let built = getenv("MACNTFS_CORPUS_DIR").map { URL(fileURLWithPath: String(cString: $0)) }
            ?? tests.appendingPathComponent("Corpus/out")
        return [built, tests.appendingPathComponent("Fixtures")]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Names that exist on every NTFS volume and are not part of the test content.
    private static func isSystemName(_ name: String) -> Bool {
        name.hasPrefix("$") || name == "System Volume Information" || name == "."
    }

    private static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    func testEveryCorpusImageMatchesItsManifest() throws {
        let manifestURLs = Self.manifestDirectories
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.lastPathComponent.hasSuffix(".manifest.json") }
            .filter { url in
                // MACNTFS_CORPUS_ONLY=basic-512,sparse limits the run to some images
                guard let only = getenv("MACNTFS_CORPUS_ONLY").map({ String(cString: $0) }) else { return true }
                return only.split(separator: ",").contains { url.lastPathComponent == "\($0).manifest.json" }
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(manifestURLs.isEmpty, "No corpus images. Build them with scripts/corpus/build.sh")

        var failures: [String] = []
        for manifestURL in manifestURLs {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            XCTAssertEqual(manifest.schema, 1, "unknown manifest schema in \(manifestURL.lastPathComponent)")
            let imagePath = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.image).path

            let volume: NTFSVolume
            do {
                volume = try NTFSVolume(blockDevice: try FileBlockDevice(path: imagePath))
            } catch {
                // A refusal with a named reason is allowed only if the manifest says so for the whole image.
                failures.append("\(manifest.image): cannot open volume: \(error)")
                continue
            }

            var ok = 0, refused = 0, bad = 0
            func fail(_ entry: Entry, _ message: String) {
                bad += 1
                failures.append("\(manifest.image) \(entry.path): \(message)")
            }

            for entry in manifest.entries {
                switch entry.type {
                case "file", "hardlink", "symlink":
                    let expect = entry.expect ?? "ok"
                    do {
                        let data = try volume.readFile(at: entry.path)
                        if let size = entry.size, UInt64(data.count) != size {
                            fail(entry, "size \(data.count), manifest says \(size)")
                        } else if let hash = entry.sha256, Self.sha256Hex(data) != hash {
                            fail(entry, "WRONG BYTES returned without an error (expected \(expect))")
                        } else {
                            ok += 1
                        }
                    } catch NTFSError.unsupported(let feature) {
                        if expect == "unsupported:\(feature.rawValue)" {
                            refused += 1
                        } else {
                            fail(entry, "refused as \(feature.rawValue), manifest expects \(expect)")
                        }
                    } catch {
                        fail(entry, "read failed: \(error) (expected \(expect))")
                    }

                case "dir":
                    // Names are compared as UTF-8 bytes, because Swift's String equality merges
                    // names that differ only in Unicode normalization.
                    let expected = Set(manifest.entries
                        .filter { $0.type != "deleted" && Self.parent(of: $0.path) == entry.path && $0.path != entry.path }
                        .map { Array(($0.path as NSString).lastPathComponent.utf8) })
                    do {
                        let names = try volume.listDirectory(at: entry.path).map(\.name).filter { !Self.isSystemName($0) }
                        let listed = Set(names.map { Array($0.utf8) })
                        if listed == expected && names.count == expected.count {
                            ok += 1
                        } else {
                            let missing = expected.subtracting(listed).map { String(decoding: $0, as: UTF8.self) }.sorted().prefix(3)
                            let extra = listed.subtracting(expected).map { String(decoding: $0, as: UTF8.self) }.sorted().prefix(3)
                            fail(entry, "listing differs: missing \(Array(missing)) extra \(Array(extra)) (\(names.count) listed, \(expected.count) expected)")
                        }
                    } catch NTFSError.unsupported(let feature) {
                        // Directories that use an attribute list, or are links, are refused by design.
                        if entry.expect == "unsupported:\(feature.rawValue)" {
                            refused += 1
                        } else {
                            fail(entry, "listing refused as \(feature.rawValue), manifest expects \(entry.expect ?? "ok")")
                        }
                    } catch {
                        fail(entry, "listing failed: \(error)")
                    }

                case "deleted":
                    // A name that was deleted and created again resolves to the new file.
                    let recreated = manifest.entries.contains { $0.path == entry.path && $0.type != "deleted" }
                    if recreated || (try? volume.lookup(path: entry.path)) == nil {
                        ok += 1
                    } else {
                        fail(entry, "deleted file still resolves")
                    }

                default:
                    fail(entry, "unknown entry type '\(entry.type)'")
                }

                // Named data streams, including the streams of directories.
                if entry.type != "deleted" {
                    for stream in entry.streams ?? [] {
                        do {
                            let data = try volume.readFile(at: entry.path, stream: stream.name)
                            if UInt64(data.count) == stream.size && Self.sha256Hex(data) == stream.sha256 {
                                ok += 1
                            } else {
                                fail(entry, "stream '\(stream.name)': \(data.count) bytes, expected \(stream.size) with another hash")
                            }
                        } catch {
                            fail(entry, "stream '\(stream.name)': \(error)")
                        }
                    }
                }
            }
            print("corpus \(manifest.image): \(ok) ok, \(refused) refused with the expected error, \(bad) wrong")
        }

        XCTAssertTrue(failures.isEmpty, "\(failures.count) corpus failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }
}
