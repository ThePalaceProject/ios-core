// Palace/Fixtures/ProtocolIsolationKnownBad.swift
//
// KNOWN-BAD fixture for check-protocol-isolation.py.
//
// Expected: 1 PROTOCOL-ISO finding on `BookButtonAction` — 3 @MainActor
// conformers, protocol itself not @MainActor.

import Foundation
import UIKit

// Protocol is NOT @MainActor.
protocol BookButtonAction {
    func perform()
}

@MainActor
final class BorrowAction: BookButtonAction {
    func perform() {}
}

@MainActor
final class ReturnAction: BookButtonAction {
    func perform() {}
}

@MainActor
final class DownloadAction: BookButtonAction {
    func perform() {}
}

// Counter-example in the SAME file: this protocol is already @MainActor →
// must NOT flag.
@MainActor
protocol PresentersDelegate {
    func didPresent()
}

@MainActor
final class HomePresenter: PresentersDelegate {
    func didPresent() {}
}

@MainActor
final class CatalogPresenter: PresentersDelegate {
    func didPresent() {}
}
