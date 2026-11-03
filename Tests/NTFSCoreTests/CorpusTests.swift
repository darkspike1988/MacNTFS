// The corpus comparison hashes files with CryptoKit and runs on macOS only (the Linux job skips it).
#if canImport(CryptoKit)
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

    private struct Reparse: Decodable {
        let kind: String
        let substituteName: String
        let printName: String
        let flags: Int
    }

    private struct Entry: Decodable {
        let path: String
        let type: String
        let size: UInt64?
        let sha256: String?
        let expect: String?
        let streams: [Stream]?
        let linkTarget: String?
        let reparse: Reparse?
    }

    private struct Manifest: Decodable {
        let schema: Int
        let image: String
        let dirty: Bool?
        let hibernated: Bool?
        let entries: [Entry]
    }

    /// The built corpus (not committed) and the committed fixtures.
    /// Features the engine refuses on purpose. A manifest label `unsupported:<x>` is only accepted as a
    /// refusal for these. For any other label (attribute lists and compression were labelled before the
    /// engine could read them) the entry must read back correctly, or the test fails.
    private static let refusedOnPurpose: Set<String> = ["reparse", "encryption"]

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
        // CI sets MACNTFS_CORPUS_REQUIRE to the number of images it built. Then missing images are a failure,
        // not a skip, and a lost kernel-written image does not pass unnoticed.
        if let required = getenv("MACNTFS_CORPUS_REQUIRE").flatMap({ Int(String(cString: $0)) }) {
            XCTAssertGreaterThanOrEqual(manifestURLs.count, required, "expected at least \(required) corpus manifests")
        }
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

            // Volume state: the dirty flag and Windows hibernation, as the manifest says.
            if let dirty = manifest.dirty, volume.isDirty != dirty {
                bad += 1
                failures.append("\(manifest.image): dirty flag is \(volume.isDirty), manifest says \(dirty)")
            }
            if let hibernated = manifest.hibernated {
                let state: HibernationState?
                do {
                    state = try volume.hibernationState()
                } catch {
                    state = nil
                    failures.append("\(manifest.image): hibernationState() threw \(error)")
                }
                if (state == .hibernated) != hibernated {
                    bad += 1
                    failures.append("\(manifest.image): hibernation state is \(String(describing: state)), manifest says hibernated=\(hibernated)")
                }
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
                        if Self.refusedOnPurpose.contains(feature.rawValue) && expect == "unsupported:\(feature.rawValue)" {
                            refused += 1
                        } else {
                            fail(entry, "refused as \(feature.rawValue), but the engine must read this (manifest label: \(expect))")
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
                        if Self.refusedOnPurpose.contains(feature.rawValue) && entry.expect == "unsupported:\(feature.rawValue)" {
                            refused += 1
                        } else {
                            fail(entry, "listing refused as \(feature.rawValue), but the engine must read this (manifest label: \(entry.expect ?? "ok"))")
                        }
                    } catch {
                        fail(entry, "listing failed: \(error)")
                    }

                case "deleted":
                    // A name that was deleted and created again resolves to the new file.
                    let recreated = manifest.entries.contains { $0.path == entry.path && $0.type != "deleted" }
                    if recreated {
                        ok += 1
                    } else {
                        do {
                            _ = try volume.lookup(path: entry.path)
                            fail(entry, "deleted file still resolves")
                        } catch NTFSError.pathNotFound {
                            ok += 1
                        } catch {
                            fail(entry, "lookup of a deleted file failed with \(error) instead of 'not found'")
                        }
                    }

                default:
                    fail(entry, "unknown entry type '\(entry.type)'")
                }

                // A directory link is not listed and not followed.
                if entry.type == "symlink", let reparse = entry.reparse, reparse.kind != "symlink-file" {
                    do {
                        _ = try volume.listDirectory(at: entry.path)
                        fail(entry, "a \(reparse.kind) was listed as a directory")
                    } catch NTFSError.unsupported(.reparse) {
                        ok += 1
                    } catch {
                        fail(entry, "listing a \(reparse.kind) failed with \(error) instead of 'unsupported: reparse'")
                    }
                }

                // Where links point. Reparse points carry their raw names, Interix links their target path.
                if entry.type == "symlink" {
                    do {
                        let (record, isDirectory) = try volume.lookup(path: entry.path)
                        if let link = try volume.linkInfo(of: record) {
                            if let reparse = entry.reparse {
                                let kindMatches: Bool
                                switch reparse.kind {
                                case "junction": kindMatches = link.kind == .junction
                                case "symlink-dir": kindMatches = link.kind == .symlink && isDirectory
                                case "symlink-file": kindMatches = link.kind == .symlink && !isDirectory
                                default: kindMatches = false
                                }
                                if kindMatches && link.substituteName == reparse.substituteName
                                    && link.printName == reparse.printName && Int(link.flags) == reparse.flags {
                                    ok += 1
                                } else {
                                    fail(entry, "link is \(link), manifest says \(reparse)")
                                }
                            } else if link.kind == .interixSymlink && link.target == entry.linkTarget {
                                ok += 1
                            } else {
                                fail(entry, "link target '\(link.target)', manifest says '\(entry.linkTarget ?? "-")'")
                            }
                        } else {
                            fail(entry, "not recognised as a link")
                        }
                    } catch {
                        fail(entry, "link: \(error)")
                    }
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
#endif
