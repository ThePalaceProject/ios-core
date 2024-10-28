////
////  TPPEPUBViewController.swift
////
////  Created by Alexandre Camilleri on 7/3/17.
////
////  Copyright 2018 European Digital Reading Lab. All rights reserved.
////  Licensed to the Readium Foundation under one or more contributor license agreements.
////  Use of this source code is governed by a BSD-style license which is detailed in the
////  LICENSE file present in the project repository where this source code is maintained.
////
//
//import UIKit
//import SwiftUI
//import ReadiumShared
//import ReadiumNavigator
//import WebKit
//
//class TPPEPUBViewController: TPPBaseReaderViewController {
//  var popoverUserconfigurationAnchor: UIBarButtonItem?
//  private let systemUserInterfaceStyle: UIUserInterfaceStyle
//  let searchButton = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(presentEPUBSearch))
//
//  private var preferences: EPUBPreferences
//
//  init(publication: Publication,
//       book: TPPBook,
//       initialLocation: Locator?,
//       resourcesServer: HTTPServer,
//       preferences: EPUBPreferences = .init(),
//       forSample: Bool = false) {
//
//    self.preferences = preferences
//
//    systemUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
//    let safeAreaInsets = UIApplication.shared.keyWindow?.safeAreaInsets ?? UIEdgeInsets()
//    let overlayLabelInset = TPPBaseReaderViewController.overlayLabelMargin * 2 // Vertical margin for labels
//    let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
//      .compact: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom)),
//      .regular: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom))
//    ]
//
//    var config = EPUBNavigatorViewController.Configuration()
//    config.preferences = preferences
//    config.preloadPreviousPositionCount = 2
//    config.preloadNextPositionCount = 2
//    config.debugState = false
//    config.decorationTemplates = HTMLDecorationTemplate.defaultTemplates()
//    config.editingActions = [.lookup]
//    config.contentInset = contentInset
//
//    let navigator: EPUBNavigatorViewController
//    do {
//      navigator = try EPUBNavigatorViewController(publication: publication,
//                                                  initialLocation: initialLocation,
//                                                  config: config,
//                                                  httpServer: resourcesServer)
//    } catch {
//      fatalError("Failed to initialize EPUBNavigatorViewController: \(error)")
//    }
//
//    super.init(navigator: navigator, publication: publication, book: book, forSample: forSample, initialLocation: initialLocation)
//
//    self.addChild(navigator)
//    self.view.addSubview(navigator.view)
//    navigator.delegate = self
//    navigator.view.frame = self.view.bounds
//    navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
//    
//    navigator.didMove(toParent: self)
//  }
//
//  var epubNavigator: EPUBNavigatorViewController {
//    return navigator as! EPUBNavigatorViewController
//  }
//
//  override func willMove(toParent parent: UIViewController?) {
//    super.willMove(toParent: parent)
//
//    // Restore catalog default UI colors
//    navigationController?.navigationBar.barStyle = .default
//    navigationController?.navigationBar.barTintColor = nil
//  }
//
//  override open func viewWillAppear(_ animated: Bool) {
//    super.viewWillAppear(animated)
//    setUIColor(for: preferences)
//  }
//
//  override open func viewWillDisappear(_ animated: Bool) {
//    super.viewWillDisappear(animated)
//    if let appearance = TPPConfiguration.defaultAppearance() {
//      navigationController?.navigationBar.setAppearance(appearance)
//      navigationController?.navigationBar.forceUpdateAppearance(style: systemUserInterfaceStyle)
//    }
//
//    navigationController?.navigationBar.tintColor = TPPConfiguration.iconColor()
//    tabBarController?.tabBar.tintColor = TPPConfiguration.iconColor()
//  }
//
//  override func makeNavigationBarButtons() -> [UIBarButtonItem] {
//    var buttons = super.makeNavigationBarButtons()
//
//    let userSettingsButton = UIBarButtonItem(image: UIImage(named: "Format"),
//                                             style: .plain,
//                                             target: self,
//                                             action: #selector(presentUserSettings))
//    userSettingsButton.accessibilityLabel = Strings.TPPEPUBViewController.readerSettings
//    buttons.insert(userSettingsButton, at: 1)
//    popoverUserconfigurationAnchor = userSettingsButton
//    buttons.append(searchButton)
//
//    return buttons
//  }
//
//  @objc func presentUserSettings() {
//    let vc = TPPReaderSettingsVC.makeSwiftUIView(preferences: preferences, delegate: self)
//    vc.modalPresentationStyle = .popover
//    vc.popoverPresentationController?.delegate = self
//    vc.popoverPresentationController?.barButtonItem = popoverUserconfigurationAnchor
//    vc.preferredContentSize = CGSize(width: 320, height: 240)
//
//    present(vc, animated: true) {
//      vc.popoverPresentationController?.passthroughViews = nil
//    }
//  }
//
//  @objc func presentEPUBSearch() {
//    let searchViewModel = EPUBSearchViewModel(publication: publication)
//    searchViewModel.delegate = self
//    let searchView = EPUBSearchView(viewModel: searchViewModel)
//    let hostingController = UIHostingController(rootView: searchView, ignoreSafeArea: true)
//    self.present(hostingController, animated: true)
//  }
//}
//
//// MARK: - TPPReaderSettingsDelegate
//
//extension TPPEPUBViewController: TPPReaderSettingsDelegate {
//  func getUserPreferences() -> ReadiumNavigator.EPUBPreferences {
//    return preferences
//  }
//
//  func updateUserPreferencesStyle() {
//    DispatchQueue.main.async {
//      self.epubNavigator.submitPreferences(self.preferences) // Apply preferences
//    }
//  }
//
//  func setUIColor(for appearance: ReadiumNavigator.EPUBPreferences) {
//
//    navigator.view.backgroundColor = appearance.backgroundColor?.uiColor
//    view.backgroundColor = appearance.backgroundColor?.uiColor
//    view.tintColor = appearance.textColor?.uiColor
//    navigationController?.navigationBar.setAppearance(TPPConfiguration.appearance(withBackgroundColor: appearance.backgroundColor?.uiColor))
//    if let backgroundColor = preferences.backgroundColor?.uiColor, let textColor = preferences.textColor?.uiColor {
//      navigator.view.backgroundColor = backgroundColor
//      view.backgroundColor = backgroundColor
//      view.tintColor = textColor
//
//      navigationController?.navigationBar.setAppearance(TPPConfiguration.appearance(withBackgroundColor: backgroundColor))
//
//      let isDarkText = (textColor == .black)
//      navigationController?.navigationBar.forceUpdateAppearance(style: isDarkText ? .light : .dark)
//
//      navigationController?.navigationBar.tintColor = textColor
//      tabBarController?.tabBar.tintColor = textColor
//    }
//  }
//}
//
//
//extension TPPEPUBViewController: EPUBNavigatorDelegate {
//}
//
//// MARK: - UIGestureRecognizerDelegate
//
//extension TPPEPUBViewController: UIGestureRecognizerDelegate {
//  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
//    return true
//  }
//}
//
//// MARK: - UIPopoverPresentationControllerDelegate
//
//extension TPPEPUBViewController: UIPopoverPresentationControllerDelegate {
//  // Prevent the popOver to be presented fullscreen on iPhones.
//  func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle
//  {
//    return .none
//  }
//}
//
//extension TPPEPUBViewController: EPUBSearchDelegate {
//  func didSelect(location: ReadiumShared.Locator) {
//
//    presentedViewController?.dismiss(animated: true) { [weak self] in
//      guard let self = self else { return }
//
//      Task {
//        await self.navigator.go(to: location)
//
//        if let decorableNavigator = self.navigator as? DecorableNavigator {
//          var decorations: [Decoration] = []
//          decorations.append(Decoration(
//            id: "search",
//            locator: location,
//            style: .highlight(tint: .red)))
//          await decorableNavigator.apply(decorations: decorations, in: "search")
//        }
//      }
//    }
//  }
//}

import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
import WebKit

class TPPEPUBViewController: TPPBaseReaderViewController {
  var popoverUserconfigurationAnchor: UIBarButtonItem?
  private let systemUserInterfaceStyle: UIUserInterfaceStyle
  let searchButton = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(presentEPUBSearch))
  private var preferences: EPUBPreferences

  init(publication: Publication,
       book: TPPBook,
       initialLocation: Locator?,
       resourcesServer: HTTPServer,
       preferences: EPUBPreferences = .init(),
       forSample: Bool = false) {

    var updatedPreferences = preferences
    updatedPreferences.backgroundColor = ReadiumNavigator.Color.init(color: .black)
    updatedPreferences.textColor = ReadiumNavigator.Color.init(color: .white)

    self.systemUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
    self.preferences = updatedPreferences
    let safeAreaInsets = UIApplication.shared.keyWindow?.safeAreaInsets ?? UIEdgeInsets()
    let overlayLabelInset = TPPBaseReaderViewController.overlayLabelMargin * 2
    let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
      .compact: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom)),
      .regular: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom))
    ]

    var config = EPUBNavigatorViewController.Configuration()
    config.preferences = updatedPreferences
    config.preloadPreviousPositionCount = 2
    config.preloadNextPositionCount = 2
    config.debugState = false
    config.decorationTemplates = HTMLDecorationTemplate.defaultTemplates()
    config.editingActions = [.lookup]
    config.contentInset = contentInset

    let navigator: EPUBNavigatorViewController
    do {
      navigator = try EPUBNavigatorViewController(publication: publication,
                                                  initialLocation: initialLocation,
                                                  config: config,
                                                  httpServer: resourcesServer)
    } catch {
      fatalError("Failed to initialize EPUBNavigatorViewController: \(error)")
    }
    super.init(navigator: navigator, publication: publication, book: book, forSample: forSample, initialLocation: initialLocation)


    self.addChild(navigator)
    self.view.addSubview(navigator.view)
    navigator.delegate = self
    navigator.view.frame = self.view.bounds
    navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    navigator.didMove(toParent: self)

    self.setUIColor(for: preferences)

    log(.info, "TPPEPUBViewController initialized with publication: \(publication.metadata.title ?? "Unknown Title").")
  }

  var epubNavigator: EPUBNavigatorViewController {
    return navigator as! EPUBNavigatorViewController
  }

  override func willMove(toParent parent: UIViewController?) {
    super.willMove(toParent: parent)
    navigationController?.navigationBar.barStyle = .default
    navigationController?.navigationBar.barTintColor = nil
    log(.info, "Moving TPPEPUBViewController to parent: \(String(describing: parent)).")
  }

  override open func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    setUIColor(for: preferences)
    log(.info, "TPPEPUBViewController will appear. UI color set based on preferences.")
  }

  override open func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if let appearance = TPPConfiguration.defaultAppearance() {
      navigationController?.navigationBar.setAppearance(appearance)
      navigationController?.navigationBar.forceUpdateAppearance(style: systemUserInterfaceStyle)
      log(.info, "View is disappearing, restored default navigation bar appearance.")
    }
    navigationController?.navigationBar.tintColor = TPPConfiguration.iconColor()
    tabBarController?.tabBar.tintColor = TPPConfiguration.iconColor()
  }

  override func makeNavigationBarButtons() -> [UIBarButtonItem] {
    var buttons = super.makeNavigationBarButtons()
    let userSettingsButton = UIBarButtonItem(image: UIImage(named: "Format"),
                                             style: .plain,
                                             target: self,
                                             action: #selector(presentUserSettings))
    userSettingsButton.accessibilityLabel = Strings.TPPEPUBViewController.readerSettings
    buttons.insert(userSettingsButton, at: 1)
    popoverUserconfigurationAnchor = userSettingsButton
    buttons.append(searchButton)
    log(.info, "Navigation bar buttons set with user settings and search button.")
    return buttons
  }

  @objc func presentUserSettings() {
    let vc = TPPReaderSettingsVC.makeSwiftUIView(preferences: preferences, delegate: self)
    vc.modalPresentationStyle = .popover
    vc.popoverPresentationController?.delegate = self
    vc.popoverPresentationController?.barButtonItem = popoverUserconfigurationAnchor
    vc.preferredContentSize = CGSize(width: 320, height: 240)
    present(vc, animated: true) {
      vc.popoverPresentationController?.passthroughViews = nil
      self.log(.info, "User settings presented in popover.")
    }
  }

  @objc func presentEPUBSearch() {
    let searchViewModel = EPUBSearchViewModel(publication: publication)
    searchViewModel.delegate = self
    let searchView = EPUBSearchView(viewModel: searchViewModel)
    let hostingController = UIHostingController(rootView: searchView, ignoreSafeArea: true)
    present(hostingController, animated: true)
    self.log(.info, "Presented EPUB search view.")
  }
}

// MARK: - TPPReaderSettingsDelegate

extension TPPEPUBViewController: TPPReaderSettingsDelegate {
  func getUserPreferences() -> ReadiumNavigator.EPUBPreferences {
    log(.info, "Fetching user preferences.")
    return preferences
  }

  func updateUserPreferencesStyle() {
    DispatchQueue.main.async {
      self.epubNavigator.submitPreferences(self.preferences)
      self.log(.info, "User preferences style updated.")
    }
  }

  func setUIColor(for appearance: ReadiumNavigator.EPUBPreferences) {
    log(.debug, "Setting UI color based on appearance preferences.")
    navigator.view.backgroundColor = appearance.backgroundColor?.uiColor
    view.backgroundColor = appearance.backgroundColor?.uiColor
    view.tintColor = appearance.textColor?.uiColor
    navigationController?.navigationBar.setAppearance(TPPConfiguration.appearance(withBackgroundColor: appearance.backgroundColor?.uiColor))

    if let backgroundColor = preferences.backgroundColor?.uiColor, let textColor = preferences.textColor?.uiColor {
      navigator.view.backgroundColor = backgroundColor
      view.backgroundColor = backgroundColor
      view.tintColor = textColor

      navigationController?.navigationBar.setAppearance(TPPConfiguration.appearance(withBackgroundColor: backgroundColor))
      let isDarkText = (textColor == .black)
      navigationController?.navigationBar.forceUpdateAppearance(style: isDarkText ? .light : .dark)
      navigationController?.navigationBar.tintColor = textColor
      tabBarController?.tabBar.tintColor = textColor
      log(.info, "Colors set for background and text: Background - \(backgroundColor), Text - \(textColor)")
    }
  }
}

// MARK: - EPUBNavigatorDelegate

extension TPPEPUBViewController: EPUBNavigatorDelegate { }

// MARK: - UIPopoverPresentationControllerDelegate

extension TPPEPUBViewController: UIPopoverPresentationControllerDelegate {
  func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
    log(.info, "Popover adaptive presentation style requested.")
    return .none
  }
}

// MARK: - EPUBSearchDelegate

extension TPPEPUBViewController: EPUBSearchDelegate {
  func didSelect(location: ReadiumShared.Locator) {
    log(.info, "Search result selected, navigating to location.")
    presentedViewController?.dismiss(animated: true) { [weak self] in
      guard let self = self else { return }
      Task {
        await self.navigator.go(to: location)
        self.log(.info, "Navigated to search result location: \(location).")

        if let decorableNavigator = self.navigator as? DecorableNavigator {
          let decorations = [
            Decoration(id: "search", locator: location, style: .highlight(tint: .red))
          ]
          await decorableNavigator.apply(decorations: decorations, in: "search")
          self.log(.debug, "Applied decoration to highlight search result at location.")
        }
      }
    }
  }
}
