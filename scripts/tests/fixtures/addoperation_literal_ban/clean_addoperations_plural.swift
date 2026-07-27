import Foundation

/// `addOperations` (plural, array API) is out of scope for this ban — it does
/// not take a trailing closure and is not part of the #1338 predicate.
final class CleanAddOperationsPlural {
    func schedule() {
        let op1 = BlockOperation()
        let op2 = BlockOperation()
        OperationQueue().addOperations([op1, op2], waitUntilFinished: false)
    }
}
