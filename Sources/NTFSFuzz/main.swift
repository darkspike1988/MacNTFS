// Without a fuzzing engine this runs the inputs named on the command line once each,
// so a crash found by the fuzzer can be reproduced: `NTFSFuzz crash-input-file`.
// A build with -D FUZZING_ENGINE and -sanitize=fuzzer leaves out main, because libFuzzer provides it.
#if !FUZZING_ENGINE
import Foundation

for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        exit(1)
    }
    data.withUnsafeBytes { raw in
        FuzzTarget.shared.run(raw.bindMemory(to: UInt8.self))
    }
    print("ran \(path) (\(data.count) bytes)")
}
#endif
