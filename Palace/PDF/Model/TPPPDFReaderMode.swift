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
  case reader, previews, bookmarks, toc, search
  
  var value: String {
    switch self {
    case .reader: return "Reader"
    case .previews: return "Page previews"
    case .bookmarks: return "Bookmarks"
    case .toc: return "TOC"
    case .search: return "Search"
    }
  }
}
