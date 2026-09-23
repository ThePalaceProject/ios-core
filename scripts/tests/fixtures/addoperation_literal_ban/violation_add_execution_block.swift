import Foundation

final class ViolationAddExecutionBlock {
    func schedule() {
        let operation = BlockOperation()
        operation.addExecutionBlock {
            print("execution block literal — banned")
        }
    }
}
