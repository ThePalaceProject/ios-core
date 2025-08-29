//
//  TPPMyBooksViewController.swift
//  Palace
//
//  Created by Maurice Carrier on 1/4/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

class TPPMyBooksViewController: NSObject {
  @MainActor @objc static func makeSwiftUIView(dismissHandler: @escaping (() -> Void)) -> UIViewController {
    let root = NavigationHostView(rootView: MyBooksView(model: MyBooksViewModel()))
    let controller = UIHostingController(rootView: root)
    controller.title = Strings.MyBooksView.navTitle
    controller.tabBarItem.image = UIImage(named: "MyBooks")
    return controller
  }
}
