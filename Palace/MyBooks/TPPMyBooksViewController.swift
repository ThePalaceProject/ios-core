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
  @objc static func makeSwiftUIView(dismissHandler: @escaping (() -> Void)) -> UIViewController {
    let controller = UIHostingController(rootView: MyBooksView(model: MyBooksViewModel()))
    controller.title = Strings.MyBooksView.navTitle
    controller.tabBarItem.image = UIImage(named: "MyBooks")
    let navigationController = UINavigationController(rootViewController: controller)

    return navigationController
  }
}
