import Foundation

final class ViolationBlockOperationLabeled {
    func schedule() {
        let operation = BlockOperation(block: {
            print("labeled block literal — banned")
        })
        OperationQueue().addOperation(operation)
    }
}
