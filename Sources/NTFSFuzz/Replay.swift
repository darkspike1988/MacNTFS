// Without a fuzzing engine this runs the inputs named on the command line once each,
// so a crash found by the fuzzer can be reproduced: `NTFSFuzz crash-input-file`.
// A build with -D FUZZING_ENGINE and -sanitize=fuzzer leaves out the entry point, because libFuzzer provides main.
#if !FUZZING_ENGINE
import Foundation

@main
enum Replay {
    static func main() {
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
    }
}
#else
// SwiftPM links an executable with `main` as an alias of `NTFSFuzz_main`, which hides the main of libFuzzer.
// So this entry point hands the command line to the driver of libFuzzer.
@_silgen_name("LLVMFuzzerRunDriver")
private func runDriver(
    _ argc: UnsafeMutablePointer<CInt>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
    _ testOneInput: @convention(c) (UnsafePointer<UInt8>, Int) -> CInt
) -> CInt

@_cdecl("NTFSFuzz_main")
func fuzzEntryPoint(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
    var count = argc
    var arguments = argv
    return runDriver(&count, &arguments) { bytes, size in fuzzOneInput(bytes, size) }
}
#endif
