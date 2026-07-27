import Foundation

final class ViolationBlockOperationInit {
    func schedule() {
        let operation = BlockOperation {
            print("BlockOperation trailing-closure literal — banned")
        }
        OperationQueue().addOperation(operation)
    }
}
