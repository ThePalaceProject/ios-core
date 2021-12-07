//
//  TPPSettingsViewController.swift
//  Palace
//
//  Created by Maurice Carrier on 12/2/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

class TPPSettingsViewController: NSObject {
  @objc static func makeSwiftUIView(dismissHandler: @escaping (() -> Void)) -> UIViewController {
    let controller = UIHostingController(rootView: TPPSettingsView())
    controller.title = DisplayStrings.Settings.settings
    controller.tabBarItem.image = UIImage(named: "Settings")
    let navigationController = UINavigationController(rootViewController: controller)

    return navigationController
  }
}
