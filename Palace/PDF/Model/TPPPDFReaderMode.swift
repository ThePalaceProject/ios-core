//
//  TPPPDFReaderMode.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

/// Reader mode
///
/// Used to determine current reader mode in `TPPDFNavigation`, and view roles
enum TPPPDFReaderMode {
  case reader
  case previews
  case bookmarks
  case toc
  case search

  var value: String {
    switch self {
    case .reader: "Reader"
    case .previews: "Page previews"
    case .bookmarks: "Bookmarks"
    case .toc: "TOC"
    case .search: "Search"
    }
  }
}
