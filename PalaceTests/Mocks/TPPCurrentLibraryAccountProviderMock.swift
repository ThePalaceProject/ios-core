//
//  TPPCurrentLibraryAccountProviderMock.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2021-03-11.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPCurrentLibraryAccountProviderMock: NSObject, TPPCurrentLibraryAccountProvider {
  var currentAccount: Account?
  
  override init() {
    let feedURL = Bundle(for: TPPLibraryAccountMock.self)
      .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!

    let simplyeAuthDocURL = Bundle(for: TPPLibraryAccountMock.self)
    .url(forResource: "simplye_authentication_document", withExtension: "json")!
    
    let feedData = try! Data(contentsOf: feedURL)
    let feed = try! OPDS2CatalogsFeed.fromData(feedData)

    currentAccount = Account(publication: feed.catalogs.first(where: { $0.metadata.title == "The SimplyE Collection" })!, imageCache: MockImageCache())
    
    super.init()
    
    currentAccount?.authenticationDocument = try! OPDS2AuthenticationDocument.fromData(try Data(contentsOf: simplyeAuthDocURL))
  }
}
