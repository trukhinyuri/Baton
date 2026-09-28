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
}
