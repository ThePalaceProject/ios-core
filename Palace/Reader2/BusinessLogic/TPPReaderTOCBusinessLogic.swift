//
//  TPPReaderTOCBusinessLogic.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 4/23/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import R2Shared

typealias TPPReaderTOCLink = (level: Int, link: Link)

/// This class captures the business logic related to the Table Of Contents
/// for a given Readium 2 Publication.
class TPPReaderTOCBusinessLogic {
  var tocElements: [TPPReaderTOCLink] = []
  private let publication: Publication
  private let currentLocation: Locator? // for current chapter

  init(r2Publication: Publication, currentLocation: Locator?) {
    self.publication = r2Publication
    self.currentLocation = currentLocation
    self.tocElements = flatten(publication.tableOfContents)
  }

  private func flatten(_ links: [Link], level: Int = 0) -> [(level: Int, link: Link)] {
    return links.flatMap { [(level, $0)] + flatten($0.children, level: level + 1) }
  }

  var tocDisplayTitle: String {
    Strings.TPPReaderTOCBusinessLogic.tocDisplayTitle
  }

  func tocLocator(at index: Int) -> Locator? {
    guard tocElements.indices.contains(index) else {
      return nil
    }
    return Locator(link: tocElements[index].link)
  }

  func shouldSelectTOCItem(at index: Int) -> Bool {
    // If the locator's href is #, then the item is not a link.
    guard let locator = tocLocator(at: index), locator.href != "#" else {
      return false
    }
    return true
  }

  func titleAndLevel(forItemAt index: Int) -> (title: String, level: Int) {
    let item = tocElements[index]
    return (title: (item.link.title ?? item.link.href), level: item.level)
  }

  func title(for href: String) -> String? {
    for tocElement in tocElements {
      if tocElement.link.href.contains(href) {
        return tocElement.link.title ?? tocElement.link.href
      }
    }
    return nil
  }

  func isCurrentChapterTitled(_ title: String) -> Bool {
    guard let currentLocationTitle = currentLocation?.title?.lowercased() else {
      return false
    }

    return title.lowercased() == currentLocationTitle
  }
}
