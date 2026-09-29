import Foundation
import Testing

@testable import BatonKit

@Suite("Atomic engine installation")
struct EngineInstallTests {
    private enum Fault: Error { case copy, signature, exchange, rollback }
    private let fm = FileManager.default

    private func app(in root: URL, name: String, version: String) throws -> URL {
        let url = root.appending(path: name)
        let executable = url.appending(path: "Contents/MacOS/Claude")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# \(version)\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleVersion": version, "CFBundleIdentifier": "test.Claude", "CFBundleExecutable": "Claude", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appending(path: "Contents/Info.plist"))
        return url
    }

    private func version(_ app: URL) throws -> String {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        return info["CFBundleVersion"] as! String
    }

    private func staging(in root: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("-install-") }
    }

    @Test func replacementKeepsOldEngineUntilValidatedThenExchangesAtomically() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        var observedBackup = false
        try EngineInstall.install(
            from: source, to: destination,
            validate: { url in
                if url.path != destination.path {
                    #expect(try version(destination) == "1")
                } else {
                    #expect(try version(destination) == "2")
                    let backups = try staging(in: box.root)
                    observedBackup = try backups.count == 1 && version(backups[0]) == "1"
                }
            })
        #expect(observedBackup)
        #expect(try version(destination) == "2")
        #expect(try version(source) == "2")
        #expect(try staging(in: box.root).isEmpty)
    }

    @Test func partialCopyFailureLeavesOldBundleAndRemovesOnlyItsOwnStaging() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        let unrelated = box.root.appending(path: ".other-install-unfinished.app")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: false)
        #expect(throws: Fault.copy) {
            try EngineInstall.install(
                from: source, to: destination,
                copy: { _, partial in
                    try fm.createDirectory(at: partial, withIntermediateDirectories: false)
                    try Data("partial".utf8).write(to: partial.appending(path: "partial"))
                    throw Fault.copy
                }, validate: { _ in })
        }
        #expect(try version(destination) == "1")
        #expect(try staging(in: box.root).map(\.lastPathComponent) == [unrelated.lastPathComponent])
    }

    /// Versions are compared part by part as numbers, and an engine is never replaced with an older Claude.
    @Test func comparesVersionsAsNumbersAndNeverDowngrades() throws {
        #expect(EngineInstall.isOlder("2.9939.9", than: "2.9939.10"), "not as text")
        #expect(!EngineInstall.isOlder("2.9939.10", than: "2.9939.9"))
        #expect(!EngineInstall.isOlder("2.9939.10", than: "2.9939.10"))
        #expect(ProfileManager.isOutdated(engine: "2.9939.9", installed: "2.9939.10"), "an update")
        #expect(!ProfileManager.isOutdated(engine: "2.9939.10", installed: "2.9939.10"), "equal")
        #expect(!ProfileManager.isOutdated(engine: "2.9939.10", installed: "2.9939.9"), "a downgrade isn't an update")
        #expect(ProfileManager.isOutdated(engine: nil, installed: "2.9939.9"), "an engine without a version")
        #expect(!ProfileManager.isOutdated(engine: "2.9939.9", installed: nil), "Claude Desktop unreadable")

        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let older = try app(in: box.root, name: "source.app", version: "2.9939.9")
        let destination = try app(in: box.root, name: "engine.app", version: "2.9939.10")
        #expect(throws: (any Error).self) { try EngineInstall.install(from: older, to: destination, validate: { _ in }) }
        #expect(try version(destination) == "2.9939.10", "kept")
        #expect(try staging(in: box.root).isEmpty)
        let same = try app(in: box.root, name: "same.app", version: "2.9939.10")
        try EngineInstall.install(from: same, to: destination, validate: { _ in })
        let newer = try app(in: box.root, name: "newer.app", version: "2.9940.0")
        try EngineInstall.install(from: newer, to: destination, validate: { _ in })
        #expect(try version(destination) == "2.9940.0")
    }

    @Test func invalidStagingOrChangedVersionNeverReplacesOldEngine() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        #expect(throws: (any Error).self) {
            try EngineInstall.install(
                from: source, to: destination,
                copy: { _, stage in
                    _ = try app(in: stage.deletingLastPathComponent(), name: stage.lastPathComponent, version: "3")
                }, validate: { _ in })
        }
        #expect(try version(destination) == "1")
        #expect(try staging(in: box.root).isEmpty)
        try fm.removeItem(at: source.appending(path: "Contents/MacOS/Claude"))
        #expect(throws: (any Error).self) {
            try EngineInstall.install(from: source, to: destination, validate: { _ in })
        }
        #expect(try version(destination) == "1")
    }

    @Test func failedValidationBeforeSwapPreservesOldEngine() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        #expect(throws: Fault.signature) {
            try EngineInstall.install(
                from: source, to: destination,
                validate: { url in
                    if url.path != source.path { throw Fault.signature }
                })
        }
        #expect(try version(destination) == "1")
        #expect(try staging(in: box.root).isEmpty)
    }

    @Test func swapFailureLeavesOldEngineInPlace() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        #expect(throws: Fault.exchange) {
            try EngineInstall.install(from: source, to: destination, validate: { _ in }, exchange: { _, _ in throw Fault.exchange })
        }
        #expect(try version(destination) == "1")
        #expect(try staging(in: box.root).isEmpty)
    }

    @Test func failedInstalledValidationRollsBackToExactOldBundle() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        let original = try Data(contentsOf: destination.appending(path: "Contents/MacOS/Claude"))
        #expect(throws: Fault.signature) {
            try EngineInstall.install(
                from: source, to: destination,
                validate: { url in
                    if url.path == destination.path { throw Fault.signature }
                })
        }
        #expect(try version(destination) == "1")
        #expect(try Data(contentsOf: destination.appending(path: "Contents/MacOS/Claude")) == original)
        #expect(try staging(in: box.root).isEmpty)
    }

    @Test func rollbackFailureKeepsRecoverableOldBundleAndReportsItsPath() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        var exchanges = 0
        do {
            try EngineInstall.install(
                from: source, to: destination,
                validate: { url in
                    if url.path == destination.path { throw Fault.signature }
                },
                exchange: { first, second in
                    exchanges += 1
                    if exchanges == 2 { throw Fault.rollback }
                    try EngineInstall.exchangeBundles(first, second)
                })
            Issue.record("Expected rollback failure")
        } catch EngineInstall.InstallError.rollbackFailed(let backup, _) {
            #expect(try version(backup) == "1")
            #expect(try staging(in: box.root).map(\.lastPathComponent) == [backup.lastPathComponent])
        }
        #expect(exchanges == 2)
    }

    @Test func firstInstallWorksAndFailedFirstInstallLeavesNoEngine() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = box.root.appending(path: "engine.app")
        #expect(throws: Fault.signature) {
            try EngineInstall.install(
                from: source, to: destination,
                validate: { url in
                    if url.path == destination.path { throw Fault.signature }
                })
        }
        #expect(!fm.fileExists(atPath: destination.path))
        try EngineInstall.install(from: source, to: destination, validate: { _ in })
        #expect(try version(destination) == "2")
        #expect(try staging(in: box.root).isEmpty)
    }

    @Test func rejectsSymlinkDestinationAndOverlappingAppPaths() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let linked = box.root.appending(path: "linked.app")
        try fm.createSymbolicLink(at: linked, withDestinationURL: source)
        #expect(throws: (any Error).self) { try EngineInstall.install(from: source, to: linked, validate: { _ in }) }
        #expect(throws: (any Error).self) { try EngineInstall.install(from: source, to: source.appending(path: "child.app"), validate: { _ in }) }
        #expect(try version(source) == "2")
        #expect(try fm.destinationOfSymbolicLink(atPath: linked.path) == source.path)
    }

    @Test func realSignatureCheckRejectsUnsignedBundleWithoutRemovingOldEngine() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "source.app", version: "2")
        let destination = try app(in: box.root, name: "engine.app", version: "1")
        #expect(throws: (any Error).self) { try EngineInstall.install(from: source, to: destination) }
        #expect(try version(destination) == "1")
    }

    /// A lookalike with Claude's bundle id and a valid signature that isn't Anthropic's, here an ad hoc one, is never
    /// copied into a profile, and `baton doctor` says why.
    @Test func validSignatureFromAnyoneButAnthropicIsRefused() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let lookalike = box.root.appending(path: "Downloads/Claude.app")
        try fm.createDirectory(at: lookalike.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: lookalike.appending(path: "Contents/MacOS/Claude"))
        let info = [
            "CFBundleVersion": "99", "CFBundleIdentifier": ClaudeVersion.bundleIdentifier, "CFBundleExecutable": "Claude",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: lookalike.appending(path: "Contents/Info.plist"))
        #expect(ProfileManager.run("/usr/bin/codesign", ["--sign", "-", "--force", lookalike.path]) == 0, "signed ad hoc")
        #expect(ProfileManager.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", lookalike.path]) == 0, "a valid signature")

        let destination = try app(in: box.root, name: "engine.app", version: "1")
        #expect {
            try EngineInstall.install(from: lookalike, to: destination)
        } throws: { error in
            error.localizedDescription.contains("isn't Claude Desktop as Anthropic signs it")
        }
        #expect(try version(destination) == "1")
        #expect(!ClaudeSource.isSignedByAnthropic(lookalike))
        #expect(!ClaudeSource.isSignedByAnthropic(destination), "unsigned")
        #expect(ClaudeSource.notes(paths: Paths(home: box.root, claudeApp: lookalike)).contains { $0.hasPrefix("Not signed by Anthropic") })
    }

    /// Across disks an app copy can't be a clone; `baton doctor` says so, with the size each copy takes.
    @Test func saysWhenAppCopiesAreFullCopies() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let source = try app(in: box.root, name: "Claude.app", version: "2")
        #expect(!EngineInstall.copiesAcrossDisks(from: source, to: box.paths.enginesDir), "same disk, before the folder exists")
        let devices = URL(fileURLWithPath: "/dev")
        #expect(EngineInstall.copiesAcrossDisks(from: devices, to: box.paths.enginesDir), "another disk")
        #expect(EngineInstall.size(of: source) > 0)
        let notes = ClaudeSource.notes(paths: Paths(home: box.root, claudeApp: source))
        #expect(notes.count == 1 && notes[0].hasPrefix("Not signed by Anthropic"), "\(notes)")
    }
}
