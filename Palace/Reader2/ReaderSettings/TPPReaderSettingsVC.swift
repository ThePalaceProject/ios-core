//
//  TPPReaderSettingsVC.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import UIKit
import SwiftUI
import ReadiumNavigator
import ReadiumShared

protocol TPPReaderSettingsDelegate: AnyObject {
  func getUserPreferences() -> EPUBPreferences
  func updateUserPreferencesStyle(for appearance: EPUBPreferences)
  func setUIColor(for appearance: EPUBPreferences)
}

class TPPReaderSettingsVC: UIViewController {
  static func makeSwiftUIView(preferences: EPUBPreferences, delegate: TPPReaderSettingsDelegate) -> UIViewController {
    let readerSettings = TPPReaderSettings(preferences: preferences, delegate: delegate)
    let controller = UIHostingController(rootView: TPPReaderSettingsView(settings: readerSettings))
    controller.title = NSLocalizedString("Reader Settings", comment: "Reader settings screen title")
    return controller
  }
}
