//
//  LibraryRowPresentation.swift
//  Palace
//
//  Pure presentation model for one row on the dedicated Libraries screen
//  (PP-5098). Kept apart from `LibrariesView` so the two tap targets a library
//  row now carries — switch, and open-library-settings — and the VoiceOver
//  labels that make them distinguishable are testable without a SwiftUI host.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Tap table

/// The two tap targets a library row carries.
enum LibraryRowTap: Equatable, CaseIterable {
    /// The leading radio control — the switch affordance.
    case selectionControl
    /// The logo + name + description, and the disclosure chevron with them.
    case rowBody
}

/// What a tap produces. Enumerated so the row's behavior is a table with a
/// finite, assertable set of cells rather than a pair of conditionals in the
/// view — the row went from one tap target to two, which doubled the space.
enum LibraryRowOutcome: Equatable {
    /// Nothing happens (the active library's selection control).
    case none
    /// Ask the patron to confirm switching to this library.
    case confirmSwitch
    /// Push this library's own settings (`AccountDetailView`).
    case openLibraryDetails
}

// MARK: - LibraryRowPresentation

/// Pure presentation model for one library row.
///
/// The row carries TWO independent tap targets, which is the whole reason this
/// is a model rather than a handful of ternaries inside the view:
///
///   * the leading selection control — switches the active library
///   * the row body + disclosure chevron — opens that library's own settings
///
/// Both targets exist on EVERY row. That is a deliberate change from the
/// Settings-inline list this screen replaces, where an *inactive* row's tap
/// opened the switch confirmation and only the *active* row navigated. The
/// updated mockups put switching on the radio control and library settings
/// behind the chevron for active and inactive libraries alike.
struct LibraryRowPresentation: Equatable {
    let libraryName: String
    let subtitle: String?
    let isCurrentLibrary: Bool

    init(libraryName: String, subtitle: String?, isCurrentLibrary: Bool) {
        self.libraryName = libraryName
        // Treat an empty description the same as none — the circulation
        // manager sends both — so no label ends up with a dangling ". ".
        self.subtitle = (subtitle?.isEmpty ?? true) ? nil : subtitle
        self.isCurrentLibrary = isCurrentLibrary
    }

    /// SF Symbol for the leading selection control. One symbol whose glyph
    /// swaps so the `.replace` content transition can cross-fade the change.
    var selectionSymbolName: String {
        isCurrentLibrary ? "checkmark.circle.fill" : "circle"
    }

    /// The row's whole behavior, as a table over (library state × tap target).
    ///
    /// The selection control is inert on the library the patron is already in
    /// — a "switch to the library you are already in?" confirmation is a dead
    /// end. The row body navigates on EVERY row, active or not.
    func outcome(of tap: LibraryRowTap) -> LibraryRowOutcome {
        switch tap {
        case .selectionControl:
            return isCurrentLibrary ? .none : .confirmSwitch
        case .rowBody:
            return .openLibraryDetails
        }
    }

    /// Whether the view renders the selection control as a live `Button` or an
    /// inert `Image`. Derived from the table so the two cannot disagree.
    var isSelectionActionable: Bool {
        outcome(of: .selectionControl) != .none
    }

    /// Whether swipe-to-delete is offered. Removing the library the patron is
    /// currently in is not supported — they must switch away first.
    var allowsDelete: Bool {
        !isCurrentLibrary
    }

    /// VoiceOver label for the selection control alone. It is a separate
    /// accessibility element from the row, so it says what it IS on the active
    /// library and what it DOES on every other one.
    var selectionAccessibilityLabel: String {
        isCurrentLibrary
            ? "\(libraryName). \(Strings.Generic.selected)"
            : String(format: Strings.Settings.switchToLibraryFormat, libraryName)
    }

    /// VoiceOver label for the row body — the navigation target. Carries the
    /// library's identity only; the selection state belongs to the control, so
    /// repeating it here would make VoiceOver say it twice per library.
    var rowAccessibilityLabel: String {
        guard let subtitle else { return libraryName }
        return "\(libraryName). \(subtitle)"
    }
}
