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
    static let pause = Image(systemName: "pause.circle")
    static let play = Image(systemName: "play.circle")
    static let stepBack = Image(systemName: "gobackward.30")
  }
  
  struct MyBooksView {
    static let bookPlaceholder = UIImage(systemName: "book.closed.fill")
    static let audiobookBadge = Image("AudiobookBadge")
    static let unreadBadge = Image("Unread")
  }
}
