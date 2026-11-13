//
//  AgeVerificationPresenterSpy.swift
//  PalaceTests
//
//  Stands in for TPPAgeCheck's presenter so tests record the age-check screen
//  instead of presenting it on the host app's window, where it outlives the
//  test and blocks later presentations.
//

import UIKit
@testable import Palace

@MainActor
final class AgeVerificationPresenterSpy {
    private(set) var presented: [UIViewController] = []

    lazy var present: @MainActor (UIViewController) -> Void = { [weak self] viewController in
        self?.presented.append(viewController)
    }
}
