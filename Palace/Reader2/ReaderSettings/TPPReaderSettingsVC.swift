//
//  TPPReaderSettingsVC.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit

// MARK: - TPPReaderSettingsDelegate

protocol TPPReaderSettingsDelegate: AnyObject {
  func getUserPreferences() -> EPUBPreferences
  func updateUserPreferencesStyle(for appearance: EPUBPreferences)
  func setUIColor(for appearance: EPUBPreferences)
}

// MARK: - TPPReaderSettingsVC

class TPPReaderSettingsVC: UIViewController {
  static func makeSwiftUIView(preferences: EPUBPreferences, delegate: TPPReaderSettingsDelegate) -> UIViewController {
    let readerSettings = TPPReaderSettings(preferences: preferences, delegate: delegate)
    let controller = UIHostingController(rootView: TPPReaderSettingsView(settings: readerSettings))
    return controller
  }
}
