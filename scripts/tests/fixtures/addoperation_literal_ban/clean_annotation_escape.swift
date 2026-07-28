import Foundation

/// A literal that is DELIBERATELY exempted via the escape-hatch annotation.
/// Only use this when a maintainer has verified the isolation is safe for
/// this specific call site (e.g. it always runs on `@MainActor` already).
final class CleanAnnotationEscape {
    func schedule() {
        // no-addoperation-literal-ban: this queue is main-only by construction
        OperationQueue.main.addOperation {
            print("intentionally allowed literal")
        }
    }
}
