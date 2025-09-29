//
//  UIHostingController+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 10/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI
import UIKit

extension UIHostingController {
  /// Initializes a hosting controller with the option to ignore safe area.
  public convenience init(rootView: Content, ignoreSafeArea: Bool) {
    self.init(rootView: rootView)
    if ignoreSafeArea {
      disableSafeArea()
    }
  }

  /// Dynamically subclasses the view to override safe area insets and keyboard handling.
  func disableSafeArea() {
    guard let originalClass = object_getClass(view) else {
      return
    }
    let subclassedName = "\(String(describing: originalClass))_IgnoreSafeArea"

    // If subclass doesn't exist, create it
    if let existingClass = NSClassFromString(subclassedName) {
      object_setClass(view, existingClass)
    } else {
      createAndRegisterSubclass(originalClass: originalClass, subclassedName: subclassedName)
    }
  }

  private func createAndRegisterSubclass(originalClass: AnyClass, subclassedName: String) {
    guard let subclass = objc_allocateClassPair(originalClass, subclassedName, 0) else {
      return
    }

    overrideSafeAreaInsets(for: subclass)
    overrideKeyboardHandling(for: subclass)

    objc_registerClassPair(subclass)
    object_setClass(view, subclass)
  }

  private func overrideSafeAreaInsets(for subclass: AnyClass) {
    let safeAreaOverride: @convention(block) (AnyObject) -> UIEdgeInsets = { _ in .zero }
    guard let method = class_getInstanceMethod(UIView.self, #selector(getter: UIView.safeAreaInsets)) else {
      return
    }
    class_addMethod(
      subclass,
      #selector(getter: UIView.safeAreaInsets),
      imp_implementationWithBlock(safeAreaOverride),
      method_getTypeEncoding(method)
    )
  }

  private func overrideKeyboardHandling(for subclass: AnyClass) {
    let keyboardOverride: @convention(block) (AnyObject, AnyObject) -> Void = { _, _ in }
    let keyboardSelector = NSSelectorFromString("keyboardWillShowWithNotification:")
    guard let method = class_getInstanceMethod(subclass, keyboardSelector) else {
      return
    }
    class_addMethod(
      subclass,
      keyboardSelector,
      imp_implementationWithBlock(keyboardOverride),
      method_getTypeEncoding(method)
    )
  }
}
