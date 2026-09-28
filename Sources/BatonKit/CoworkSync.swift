import Foundation

/// Read-only inventory of legacy Cowork cards. Claude resolves a Cowork transcript from the current
/// profile/account/organization's session runtime, not from the card's absolute `cwd`. Copying just the
/// card can produce an empty conversation and then write another account's tool setup back to its owner.
///
/// Previously copied cards and old synchronization state are deliberately preserved. Continue in the
/// owning Cowork environment, or transfer reviewed context through a new conversation/native import.
/// Never copy or link VM runtimes, grants, transcripts or cards between profiles here.
public struct CoworkSync: Sendable {
    public struct Report: Equatable, Sendable {
        public var pairs = 0
        // Kept for source compatibility. Inventory never writes, removes or backs up cards.
        public var cardsWritten = 0
        public var cardsRemoved = 0
        public var backedUp = 0
        public var accountBoundCards = 0
        public var ambiguousAccountBoundCards = 0
        /// Every observed card copy, including old cross-profile copies left untouched.
        public var cardsPreserved = 0
        public var changes: Int { cardsWritten + cardsRemoved }
    }

    static let sessionsFolder = "local-agent-mode-sessions"

    public let paths: Paths
    public let dataDirs: [URL]

    /// The old deletion baseline is no longer read or written; it cannot prove runtime ownership.
    var stateFile: URL { paths.stateDir.appending(path: "cowork-sync.json") }

    public init(paths: Paths, dataDirs: [URL]) {
        self.paths = paths
        self.dataDirs = dataDirs
    }

    /// Compatibility entry point for the combined sync. Both arguments are retained for existing callers;
    /// even when no Claude window is open this is strictly an inventory, not a transfer or deletion pass.
    @discardableResult
    public func run(propagateDeletions: Bool, now: Date = Date()) throws -> Report {
        var report = Report()
        let pairs = try self.pairs()
        report.pairs = pairs.count
        var scopes: [String: Set<String>] = [:]
        var native = Set<String>()
        for pair in pairs {
            for url in try FileManager.default.contentsOfDirectory(at: pair, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
                let data = try ScanCache.shared.value("data", of: url) { try Data(contentsOf: $0) }
                report.cardsPreserved += 1
                scopes[name, default: []].insert(SessionSync.scope(of: pair))
                if SessionSync.isAccountBound(data) { native.insert(name) }
            }
        }
        report.accountBoundCards = native.count
        report.ambiguousAccountBoundCards = native.filter { (scopes[$0]?.count ?? 0) > 1 }.count
        return report
    }

    /// Compatibility no-op. Removing a profile must not mutate another profile's legacy Cowork cards:
    /// the remaining runtime/transcript ownership must be inspected in Claude before any cleanup.
    @discardableResult
    public func removeCards(workingIn dataDir: URL, now: Date = Date()) throws -> Int { 0 }

    func pairs() throws -> [URL] { try SessionSync.sessionPairs(dataDirs: dataDirs, folder: Self.sessionsFolder) }
}
