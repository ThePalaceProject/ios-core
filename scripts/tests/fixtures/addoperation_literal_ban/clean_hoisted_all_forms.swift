import Foundation

/// APPROVED form (mirrors Palace/Utilities/ImageCache/ImageCache.swift): every
/// closure is hoisted into an explicitly-typed `let` binding BEFORE being
/// handed to the NSOperation-family API, rather than written inline as a
/// trailing-closure literal. The bound value's type comes from the `let`
/// annotation, not the poisonable imported parameter type, so passing it to
/// any of these APIs is safe under the #1338 ClangImporter bug.
final class CleanHoistedAllForms {
    private let processingQueue = OperationQueue()

    func schedule() {
        let work: @Sendable () -> Void = {
            print("hoisted addOperation work")
        }
        processingQueue.addOperation(work)

        let operation = BlockOperation()

        let executionBlock: @Sendable () -> Void = {
            print("hoisted execution block")
        }
        operation.addExecutionBlock(executionBlock)

        let completion: @Sendable () -> Void = {
            print("hoisted completion")
        }
        operation.completionBlock = completion

        processingQueue.addOperation(operation)
    }
}
