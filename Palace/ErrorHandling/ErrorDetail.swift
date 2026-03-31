//
//  ErrorDetail.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Captures full context about an error occurrence for the "View Error Details" feature.
///
/// Combines the user-facing error message, underlying technical details,
/// server problem document (if any), and the activity trail leading up to the error.
struct ErrorDetail {

    /// User-facing error title
    let title: String

    /// User-facing error message
    let message: String

    /// The underlying error (PalaceError, NSError, etc.)
    let underlyingError: Error?

    /// Server problem document, if the error came from an OPDS response
    let problemDocument: TPPProblemDocument?

    /// Activity trail leading up to the error (most recent last)
    let activityTrail: [ErrorActivityTracker.Activity]

    /// When this error detail was captured
    let timestamp: Date

    /// Book context, if the error is related to a specific book
    let bookInfo: BookInfo?

    /// Device and app context at the time of the error
    let deviceContext: DeviceContext

    // MARK: - Nested Types

    struct BookInfo {
        let identifier: String
        let title: String?
    }

    struct DeviceContext {
        let appVersion: String
        let buildNumber: String
        let iosVersion: String
        let deviceModel: String
        let libraryName: String
        let availableStorage: String
        let memoryUsage: String
    }

    // MARK: - Factory

    /// Creates an ErrorDetail by capturing the current activity trail and device context.
    static func capture(
        title: String,
        message: String,
        error: Error? = nil,
        problemDocument: TPPProblemDocument? = nil,
        bookIdentifier: String? = nil,
        bookTitle: String? = nil
    ) async -> ErrorDetail {
        let trail = await ErrorActivityTracker.shared.recentActivities(seconds: 300)

        let bookInfo: BookInfo? = bookIdentifier.map {
            BookInfo(identifier: $0, title: bookTitle)
        }

        return ErrorDetail(
            title: title,
            message: message,
            underlyingError: error,
            problemDocument: problemDocument,
            activityTrail: trail,
            timestamp: Date(),
            bookInfo: bookInfo,
            deviceContext: captureDeviceContext()
        )
    }

    /// Captures current device/app context synchronously.
    private static func captureDeviceContext(accountsManager: AccountsManager = AccountsManager.shared) -> DeviceContext {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        let libraryName = accountsManager.currentAccount?.name ?? "No library"

        // Available storage
        let storageString: String
        if let url = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            storageString = ByteCountFormatter.string(fromByteCount: url, countStyle: .file)
        } else {
            storageString = "Unknown"
        }

        // Memory usage
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let memoryString: String
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            memoryString = ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
        } else {
            memoryString = "Unknown"
        }

        return DeviceContext(
            appVersion: appVersion,
            buildNumber: buildNumber,
            iosVersion: iosVersion,
            deviceModel: deviceModel,
            libraryName: libraryName,
            availableStorage: storageString,
            memoryUsage: memoryString
        )
    }

    // MARK: - Text Export

    /// Generates a full text report suitable for sharing or copying.
    func formattedReport() -> String {
        var report = ""

        // Header
        report += "═══ Palace Error Report ═══\n"
        report += "Time: \(Self.reportDateFormatter.string(from: timestamp))\n\n"

        // Error Summary
        report += "── Error ──\n"
        report += "Title: \(title)\n"
        report += "Message: \(message)\n"

        if let error = underlyingError {
            report += "Type: \(String(describing: type(of: error)))\n"
            let nsError = error as NSError
            report += "Domain: \(nsError.domain)\n"
            report += "Code: \(nsError.code)\n"
            if let desc = nsError.localizedDescription as String?, !desc.isEmpty {
                report += "Description: \(desc)\n"
            }
            if let recovery = nsError.localizedRecoverySuggestion, !recovery.isEmpty {
                report += "Recovery: \(recovery)\n"
            }
        }

        // Problem Document
        if let doc = problemDocument {
            report += "\n── Server Response ──\n"
            if let type = doc.type { report += "Type: \(type)\n" }
            if let title = doc.title { report += "Title: \(title)\n" }
            if let status = doc.status { report += "Status: \(status)\n" }
            if let detail = doc.detail { report += "Detail: \(detail)\n" }
            if let instance = doc.instance { report += "Instance: \(instance)\n" }
        }

        // Book Info
        if let book = bookInfo {
            report += "\n── Book ──\n"
            report += "ID: \(book.identifier)\n"
            if let title = book.title { report += "Title: \(title)\n" }
        }

        // Activity Trail
        report += "\n── Activity Trail (\(activityTrail.count) entries) ──\n"
        if activityTrail.isEmpty {
            report += "(no recent activity recorded)\n"
        } else {
            for activity in activityTrail {
                report += "\(activity.displayString)\n"
            }
        }

        // Device Context
        let ctx = deviceContext
        report += "\n── Device ──\n"
        report += "App: \(ctx.appVersion) (\(ctx.buildNumber))\n"
        report += "iOS: \(ctx.iosVersion)\n"
        report += "Device: \(ctx.deviceModel)\n"
        report += "Library: \(ctx.libraryName)\n"
        report += "Storage: \(ctx.availableStorage)\n"
        report += "Memory: \(ctx.memoryUsage)\n"

        return report
    }

    private static let reportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()
}
