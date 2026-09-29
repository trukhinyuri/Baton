import Foundation

/// The app's actions still running: what the footer says while they do, and which windows have one. Each action
/// ends only itself, so a quick one (Show on an open window) no longer clears the message of a slow one (making an
/// app copy).
public struct OperationsInFlight: Equatable, Sendable {
    struct Running: Equatable, Sendable {
        var id: Int
        var message: String?
        var window: String?
    }

    private var running: [Running] = []
    private var lastID = 0

    public init() {}

    /// Starts an action; pass the result to `finish(_:)` when it ends.
    /// - Parameters:
    ///   - message: what the footer says meanwhile, such as "Opening Claude WORK…"; `nil` for a quick one.
    ///   - window: the window it acts on, whose Open button waits for it.
    public mutating func start(_ message: String?, window: String? = nil) -> Int {
        lastID += 1
        running.append(Running(id: lastID, message: message, window: window))
        return lastID
    }

    public mutating func finish(_ id: Int) { running.removeAll { $0.id == id } }

    /// The newest message among the actions still running.
    public var message: String? { running.last { $0.message != nil }?.message }

    public var isEmpty: Bool { running.isEmpty }

    public func isBusy(window: String) -> Bool { running.contains { $0.window == window } }
}
