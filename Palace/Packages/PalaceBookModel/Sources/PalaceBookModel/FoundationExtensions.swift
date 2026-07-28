//
//  FoundationExtensions.swift
//  PalaceBookModel
//
//  Wave 2a: Foundation/CoreGraphics helper extensions that the book model
//  (TPPBook / TPPReadiumBookmark / TPPBook+Presentation) depends on, relocated
//  here so the package is self-contained. These are the SINGLE SOURCE — the
//  declarations were deleted from their former app-side homes
//  (Date+NYPLAdditions.swift, Date+Extensions.swift, Int+Extensions.swift,
//  Float+TPPAdditions.swift, TPPBookCoverRegistry.swift). Wire-format writers
//  (rfc1123String / rfc339String) must stay byte-identical — do not touch the
//  format strings.
//

import Foundation
import CoreGraphics

// MARK: - Date (RFC formatters + time-until, from Date+NYPLAdditions / Date+Extensions)

public extension Date {

    /// A static date formatter to get date strings formatted per RFC 1123
    /// without incurring in the high cost of creating a new DateFormatter
    /// each time, which would be ~300% more expensive.
    static let rfc1123DateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return df
    }()

    /// A date string formatted per RFC 1123 for insertion into a HTTP
    /// header field (such as the `Expires` header in a HTTP response).
    /// Example: Wed, 25 Mar 2020 01:23:45 GMT
    var rfc1123String: String {
        return Date.rfc1123DateFormatter.string(from: self)
    }

    /// A static date formatter to get date strings formatted per RFC 339
    /// without incurring in the high cost of creating a new DateFormatter
    /// each time, which would be ~300% more expensive.
    static let rfc339StringFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
        return df
    }()

    var rfc339String: String {
        return Date.rfc339StringFormatter.string(from: self)
    }

    func timeUntil() -> (value: Int, unit: String) {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day, .hour, .minute], from: now, to: self)

        if let days = components.day, days > 0 {
            switch days {
            case 1: return (1, "day")
            default: return (days, "days")
            }
        }

        if let hours = components.hour, hours > 0 {
            return (hours, hours == 1 ? "hour" : "hours")
        }

        if let minutes = components.minute, minutes > 0 {
            return (minutes, minutes == 1 ? "minute" : "minutes")
        }

        return (0, "expired")
    }
}

// MARK: - Int (ordinal, from Int+Extensions)

public extension Int {
    func ordinal() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

// MARK: - Float (epsilon-equality + rounding, from Float+TPPAdditions)

infix operator =~= : ComparisonPrecedence

public extension Float {

    /// Performs equality check minus an epsilon
    /// - Returns: `true` if the numbers differ by less than the epsilon,
    /// `false` otherwise.
    static func =~= (a: Float, b: Float?) -> Bool {
        guard let b = b else {
            return false
        }

        return abs(a - b) < Float.ulpOfOne
    }

    func roundTo(decimalPlaces: Int) -> String {
        return String(format: "%.\(decimalPlaces)f%%", self) as String
    }
}

// MARK: - CGFloat (display-dimension sanitizing, from TPPBookCoverRegistry)

public extension CGFloat {
    /// The value when it is a finite, strictly-positive display dimension; otherwise `nil`.
    ///
    /// A view can report a `NaN`, infinite, or non-positive size while it is still
    /// laying out. Feeding such a value into `Int(_:)` traps with `EXC_BREAKPOINT`
    /// ("… not representable in Int"), and into a `CGSize` / CoreGraphics renderer
    /// produces an invalid-context crash. The cover pipeline converted a raw display
    /// height straight into an `Int` cache key and a decode dimension without this
    /// guard — the source of PP-4772 / Crashlytics `077218fc` (`fetchCoverImage`
    /// `EXC_BREAKPOINT`). Callers use this to fall back to the unsized cover path
    /// instead of trapping.
    var finitePositiveDimension: CGFloat? {
        (isFinite && self > 0) ? self : nil
    }
}
