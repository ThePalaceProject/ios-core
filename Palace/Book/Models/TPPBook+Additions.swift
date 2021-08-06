//
//  TPPBook+Additions.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 7/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPBook {
  // TODO: SIMPLY-2656 Remove this hack if possible, or at least use DI for
  // instead of implicitly using NYPLMyBooksDownloadCenter
  var url: URL? {
    return TPPMyBooksDownloadCenter.shared()?.fileURL(forBookIndentifier: identifier)
  }
}
