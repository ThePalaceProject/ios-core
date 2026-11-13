//
//  ReaderLetterboxTapGate.swift
//  Palace
//

import UIKit

/// Decides whether a tap inside the reader's navigator container belongs to the
/// letterbox rather than to one of the container's children.
///
/// The navigator's web view is inset by fixed letterboxes so page content does
/// not shift when the navigation bar appears, and that web view owns every tap
/// gesture the reader has. A tap in a letterbox therefore reached no handler and
/// did nothing, including the strip the toolbar occupies (PP-5394).
enum ReaderLetterboxTapGate {

    /// A letterbox tap is one that reached the container itself. Anything that
    /// landed on a child — the web view, the chapter scrubber — belongs to that
    /// child, so routing it here as well would toggle the chrome twice.
    static func isLetterboxTap(touchedView: UIView?, container: UIView) -> Bool {
        touchedView === container
    }
}
