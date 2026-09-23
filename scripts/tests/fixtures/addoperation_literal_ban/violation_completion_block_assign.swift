import Foundation

final class ViolationCompletionBlockAssign {
    func schedule() {
        let operation = BlockOperation()
        operation.completionBlock = {
            print("completion literal assigned directly — banned")
        }
        OperationQueue().addOperation(operation)
    }
}
