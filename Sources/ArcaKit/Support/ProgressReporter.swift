import Foundation

/// Thread-safe progress + cancellation token shared between the UI and engine.
public final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _total: Int64 = 0
    private var _completed: Int64 = 0
    private var _cancelled = false
    private var _phase: String = ""

    public init(total: Int64 = 0) { _total = total }

    public var total: Int64 { lock.withLock { _total } }
    public var completed: Int64 { lock.withLock { _completed } }
    public var phase: String { lock.withLock { _phase } }
    public var isCancelled: Bool { lock.withLock { _cancelled } }

    public var fraction: Double {
        lock.withLock { _total > 0 ? min(1, Double(_completed) / Double(_total)) : 0 }
    }

    public func cancel() { lock.withLock { _cancelled = true } }

    func reset(total: Int64, phase: String) {
        lock.withLock {
            _total = total
            _completed = 0
            _phase = phase
        }
    }

    func addTotal(_ n: Int64) { lock.withLock { _total += n } }
    func advance(by n: Int64) { lock.withLock { _completed += n } }
    func set(completed: Int64) { lock.withLock { _completed = completed } }

    func checkCancelled() throws {
        if isCancelled { throw ArchiveError.cancelled }
    }
}
