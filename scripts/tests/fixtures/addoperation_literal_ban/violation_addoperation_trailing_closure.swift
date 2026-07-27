import Foundation

/// PP-1338-class violation: a raw trailing-closure literal handed directly to
/// `addOperation`. Under Xcode 26.2's ClangImporter @MainActor-poisoning bug
/// this literal's inferred type can flip to `@MainActor`, and it SIGTRAPs the
/// instant `processingQueue` runs it off-main.
final class ViolationAddOperationTrailingClosure {
    private let processingQueue = OperationQueue()

    func schedule() {
        processingQueue.addOperation {
            print("work done inline — banned literal")
        }
    }
}
