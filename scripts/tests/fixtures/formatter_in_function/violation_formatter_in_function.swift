import Foundation

extension Date {
    var iso8601: String {
        return ISO8601DateFormatter().string(from: self)
    }
}
