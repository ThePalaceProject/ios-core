//
//  Images.swift
//  Palace
//
//  Created by Maurice Carrier on 8/18/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct ImageProviders {
    struct AudiobookSampleToolbar {
        static var pause: some View { Image(systemName: "pause.circle").resizable().accessibilityHidden(true) }
        static var play: some View { Image(systemName: "play.circle").resizable().accessibilityHidden(true) }
        static var stepBack: some View { Image(systemName: "gobackward.30").resizable().accessibilityHidden(true) }
    }

    struct MyBooksView {
        static let bookPlaceholder = UIImage(systemName: "book.closed.fill")
        static var audiobookBadge: some View { Image("AudiobookBadge").resizable().accessibilityHidden(true) }
        static var unreadBadge: some View { Image("Unread").resizable().accessibilityHidden(true) }
        static var clock: some View { Image("Clock").accessibilityHidden(true) }
        static var myLibraryIcon: some View { Image("MyLibraryIcon").accessibilityHidden(true) }
        static var search: some View { Image("Search").accessibilityHidden(true) }
        static var sort: some View { Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true) }
        static var filter: some View { Image(systemName: "line.3.horizontal.decrease").accessibilityHidden(true) }
    }
}
