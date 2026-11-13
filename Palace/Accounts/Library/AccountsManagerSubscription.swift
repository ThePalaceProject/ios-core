import Combine
import Foundation

/// Lock-backed holder for one Combine subscription, so it can be replaced or
/// cancelled from any thread. `@unchecked Sendable` invariant: `cancellable`
/// is read and written only under `lock`.
final class AccountsManagerSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: AnyCancellable?
    func hold(_ newValue: AnyCancellable) { lock.withLock { cancellable = newValue } }
    func cancel() { lock.withLock { cancellable = nil } }
    /// Stores `newValue` only when nothing is held. Returns false, and drops
    /// `newValue` (which cancels it), when a subscription is already held.
    func holdIfEmpty(_ newValue: AnyCancellable) -> Bool {
        lock.withLock {
            guard cancellable == nil else { return false }
            cancellable = newValue
            return true
        }
    }
    var isHolding: Bool { lock.withLock { cancellable != nil } }
}
