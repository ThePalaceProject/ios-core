//
//  Strings+Audiobook.swift
//  Palace
//
//  Audiobook copy kept out of Strings.swift, which is at its line-count ceiling.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

extension Strings {
    /// Shown when an OverDrive audiobook's download link expired and running
    /// fulfilment again did not produce a working one (PP-4967).
    struct OverdriveLinkRenewal {
        static let title = NSLocalizedString("Audiobook Unavailable", comment: "Title when a cold-load playback failure dismisses the player")
        static let message = NSLocalizedString("We couldn't get a new download link for this audiobook. Please try again later. If it still won't play, return the audiobook and borrow it again.", comment: "Message when an OverDrive audiobook's expired download link could not be replaced")
    }
}
