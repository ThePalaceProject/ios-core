import Combine

/// Thread-safe wrapper for Combine subjects used across actor isolation boundaries.
/// Combine's PassthroughSubject and CurrentValueSubject have internal locking
/// for `send()`, making them safe for cross-isolation use. This wrapper makes
/// that safety contract explicit via `@unchecked Sendable` instead of
/// requiring `nonisolated(unsafe)` on each property.
struct SendablePassthrough<Output: Sendable>: @unchecked Sendable {
    let subject = PassthroughSubject<Output, Never>()
    func send(_ value: Output) { subject.send(value) }
    func eraseToAnyPublisher() -> AnyPublisher<Output, Never> { subject.eraseToAnyPublisher() }
}

struct SendableCurrentValue<Output: Sendable>: @unchecked Sendable {
    let subject: CurrentValueSubject<Output, Never>
    init(_ value: Output) { subject = CurrentValueSubject(value) }
    func send(_ value: Output) { subject.send(value) }
    func eraseToAnyPublisher() -> AnyPublisher<Output, Never> { subject.eraseToAnyPublisher() }
}
