//
//  TPPReaderSettingsVC.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import UIKit
import SwiftUI
import R2Navigator
import R2Shared

protocol TPPReaderSettingsDelegate: AnyObject {
    func getUserSettings() -> UserSettings
    func updateUserSettingsStyle()
    func setUIColor(for appearance: UserProperty)
}

class TPPReaderSettingsVC: UIViewController {
  static func makeSwiftUIView(settings: UserSettings, delegate: TPPReaderSettingsDelegate) -> UIViewController {
    let readerSettings = TPPReaderSettings(userSettings: settings, delegate: delegate)
    let controller = UIHostingController(rootView: TPPReaderSettingsView(settings: readerSettings))
    return controller
  }
}
