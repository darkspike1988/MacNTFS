import FSKit
import NTFSCore

@main
@available(macOS 15.4, *)
struct MacNTFSFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: MacNTFSFileSystem { MacNTFSFileSystem() }
}
