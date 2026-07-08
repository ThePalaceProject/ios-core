//
//  FakeStreamingReaderProgressStore.swift
//  PalaceTests
//
//  Test double for StreamingReaderProgressStoring. Records the most-recent
//  save call so tests can assert the VM persisted the right offset on
//  dismiss, and lets tests pre-seed a stored progress so the VM emits
//  `.ready(_, restoredScroll:)` on init.
//

import CoreGraphics
import Foundation
@testable import Palace

final class FakeStreamingReaderProgressStore: StreamingReaderProgressStoring {
    struct SaveCall: Equatable {
        let scrollOffset: CGFloat
        let fragment: String?
        let bookID: String
    }

    private(set) var saveCalls: [SaveCall] = []
    var stubbedReads: [String: StreamingReaderProgress] = [:]

    func save(scrollOffset: CGFloat, fragment: String?, forBookID bookID: String) {
        saveCalls.append(SaveCall(scrollOffset: scrollOffset, fragment: fragment, bookID: bookID))
    }

    func read(forBookID bookID: String) -> StreamingReaderProgress? {
        stubbedReads[bookID]
    }
}
