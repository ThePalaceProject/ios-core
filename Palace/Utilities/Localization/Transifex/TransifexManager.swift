//
//  TransifexManager.swift
//  Palace
//
//  Created by Maurice Carriers on 9/6/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Transifex

@objc class TransifexManager: NSObject {
  @objc static func setup() {
    let locales = TXLocaleState(
      sourceLocale: "en",
      appLocales: ["en", "es", "it", "de", "fr"]
    )

    TXNative.initialize(
      locales: locales,
      token: TPPSecrets.transifexToken ?? ""
    )

    TXNative.fetchTranslations()
  }
}
