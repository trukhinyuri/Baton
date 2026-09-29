import Foundation
import Testing

/// scripts/verify-build.sh against a fake app, with `sysctl`, `arch`, `lipo`, `codesign` and `shasum` stubbed on the
/// `PATH`, so an Intel Mac can be played on this one.
@Suite("Verify build script")
struct VerifyBuildTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "verify-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ text: String, to path: String, executable: Bool = false) throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// Runs the script on a fake universal, signed Baton.app. `intel` makes `sysctl` say this Mac isn't Apple silicon
    /// and `arch -arm64` fail the way it does there; `arch` logs every architecture it is asked for.
    func verify(intel: Bool) throws -> (status: Int32, output: String, arches: String) {
        let app = "Baton.app/Contents"
        let info: [String: Any] = ["BatonCommit": "abc1234", "BatonVersion": "1.0.0-rc.1"]
        try fm.createDirectory(at: root.appending(path: app), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appending(path: "\(app)/Info.plist"))
        try write("", to: "\(app)/MacOS/Baton", executable: true)
        try write("#!/bin/sh\necho 'Baton 1.0.0-rc.1 (abc1234)'\n", to: "\(app)/Helpers/baton", executable: true)
        try fm.createSymbolicLink(atPath: root.appending(path: "\(app)/Helpers/claude-profiles").path, withDestinationPath: "baton")

        try write(intel ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\necho 1\n", to: "bin/sysctl", executable: true)
        let log = root.appending(path: "arches").path
        try write(
            "#!/bin/sh\necho \"$1\" >> '\(log)'\n" + (intel ? "[ \"$1\" = -arm64 ] && { echo 'Bad CPU type' >&2; exit 1; }\n" : "")
                + "shift\nexec \"$@\"\n", to: "bin/arch", executable: true)
        try write("#!/bin/sh\necho 'x86_64 arm64'\n", to: "bin/lipo", executable: true)
        try write("#!/bin/sh\n[ \"$1\" = -dv ] && echo 'CodeDirectory flags=0x10000(runtime)' >&2\nexit 0\n", to: "bin/codesign", executable: true)
        try write("#!/bin/sh\nexit 0\n", to: "bin/shasum", executable: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["scripts/verify-build.sh", root.appending(path: "Baton.app").path]
        process.currentDirectoryURL = Self.repo
        process.environment = ["PATH": root.appending(path: "bin").path + ":/usr/bin:/bin", "HOME": root.appending(path: "not-home").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let arches = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), arches)
    }

    @Test func anIntelMacChecksTheSliceItCanRun() throws {
        defer { try? fm.removeItem(at: root) }
        let result = try verify(intel: true)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("ok    helper --version runs natively (x86_64)"))
        #expect(!result.output.contains("FAIL"))
        #expect(!result.arches.contains("-arm64"), "an Intel Mac can't run arm64 code")
    }

    @Test func appleSiliconChecksBothSlices() throws {
        defer { try? fm.removeItem(at: root) }
        let result = try verify(intel: false)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("ok    helper --version runs natively (arm64)"))
        #expect(result.output.contains("ok    helper --version runs under Rosetta (x86_64)"))
    }
}
