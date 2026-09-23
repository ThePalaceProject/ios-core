//
//  Fixture: the banned raising read. `NSKeyedUnarchiver.unarchiveObject(with:)`
//  signals a corrupt archive by RAISING an uncatchable ObjC exception — measured
//  at 63 of 277 bit-flips aborting the process for a dictionary archive.
//
import Foundation

enum RaisingUnarchiverFixture {
    static func decode(_ data: Data) -> String? {
        return NSKeyedUnarchiver.unarchiveObject(with: data) as? String
    }
}
