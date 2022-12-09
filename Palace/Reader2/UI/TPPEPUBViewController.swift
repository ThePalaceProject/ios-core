//
//  TPPEPUBViewController.swift
//
//  Created by Alexandre Camilleri on 7/3/17.
//
//  Copyright 2018 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import UIKit
import R2Shared
import R2Navigator

class TPPEPUBViewController: TPPBaseReaderViewController {

  var popoverUserconfigurationAnchor: UIBarButtonItem?

  init(publication: Publication,
       book: TPPBook,
       initialLocation: Locator?,
       resourcesServer: ResourcesServer,
       forSample: Bool = false) {

    let safeAreaInsets = UIApplication.shared.keyWindow?.safeAreaInsets ?? UIEdgeInsets()
    let overlayLabelInset = TPPBaseReaderViewController.overlayLabelMargin * 2 // Vertical margin for labels
    let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
      .compact: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom)),
      .regular: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom))
    ]

    // this config was suggested by R2 engineers as a way to limit the possible
    // race conditions between restoring the initial location without
    // interfering with the web view layout timing
    // See: https://github.com/readium/r2-navigator-swift/issues/153
    var config = EPUBNavigatorViewController.Configuration()
    config.preloadPreviousPositionCount = 2
    config.preloadNextPositionCount = 2
    config.debugState = false
    config.decorationTemplates = HTMLDecorationTemplate.defaultTemplates()
    config.editingActions = [.lookup]
    config.contentInset = contentInset

    let navigator = EPUBNavigatorViewController(publication: publication,
                                                initialLocation: initialLocation,
                                                resourcesServer: resourcesServer,
                                                config: config)

    TPPAssociatedColors.shared.userSettings = navigator.userSettings
    
    // EPUBNavigatorViewController::init creates a UserSettings object and sets
    // it into the publication. However, that UserSettings object will have the
    // defaults options for the various user properties (fonts etc), so we need
    // to re-set that to reflect our ad-hoc configuration.
    publication.userProperties = navigator.userSettings.userProperties

    super.init(navigator: navigator, publication: publication, book: book, forSample: forSample)

    navigator.delegate = self
  }

  var epubNavigator: EPUBNavigatorViewController {
    return navigator as! EPUBNavigatorViewController
  }

  override func willMove(toParent parent: UIViewController?) {
    super.willMove(toParent: parent)

    // Restore catalog default UI colors
    navigationController?.navigationBar.barStyle = .default
    navigationController?.navigationBar.barTintColor = nil
  }

  override open func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if let appearance = epubNavigator.userSettings.userProperties.getProperty(reference: ReadiumCSSReference.appearance.rawValue) as? Enumerable {
      self.setUIColor(for: appearance)
    }
    if let fontFamily = epubNavigator.userSettings.userProperties.getProperty(reference: ReadiumCSSReference.fontFamily.rawValue) as? Enumerable {
      epubNavigator.userSettings.userProperties.removeProperty(forReference: ReadiumCSSReference.fontFamily)
      epubNavigator.userSettings.userProperties.addEnumerable(
        index: fontFamily.index,
        values: TPPReaderFont.allCases.map { $0.rawValue },
        reference: ReadiumCSSReference.fontFamily.rawValue,
        name: ReadiumCSSName.fontFamily.rawValue
      )
    }

    // "The --USER__advancedSettings: readium-advanced-on inline style must be
    // set for html in order for the font-size setting to work."
    // https://readium.org/readium-css/docs/CSS12-user_prefs.html#font-size
    epubNavigator.userSettings.userProperties.addSwitchable(
      onValue: TPPReaderAdvancedSettings.on.rawValue,
      offValue: TPPReaderAdvancedSettings.off.rawValue,
      on: true,
      reference: ReadiumCSSReference.publisherDefault.rawValue,
      name: ReadiumCSSName.publisherDefault.rawValue)
  }

  override open func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if let appearance = TPPConfiguration.defaultAppearance() {
      navigationController?.navigationBar.setAppearance(appearance)
      navigationController?.navigationBar.forceUpdateAppearance(style: appearance.backgroundColor == .black ? .light : .dark)
    }

    navigationController?.navigationBar.tintColor = TPPConfiguration.iconColor()
    tabBarController?.tabBar.tintColor = TPPConfiguration.iconColor()
    epubNavigator.userSettings.save()
  }

  override func makeNavigationBarButtons() -> [UIBarButtonItem] {
    var buttons = super.makeNavigationBarButtons()

    // User configuration button
    let userSettingsButton = UIBarButtonItem(image: UIImage(named: "Format"),
                                             style: .plain,
                                             target: self,
                                             action: #selector(presentUserSettings))
    userSettingsButton.accessibilityLabel = Strings.TPPEPUBViewController.readerSettings
    buttons.insert(userSettingsButton, at: 1)
    popoverUserconfigurationAnchor = userSettingsButton

    return buttons
  }

  @objc func presentUserSettings() {
    let vc = TPPReaderSettingsVC.makeSwiftUIView(settings: epubNavigator.userSettings, delegate: self)
    vc.modalPresentationStyle = .popover
    vc.popoverPresentationController?.delegate = self
    vc.popoverPresentationController?.barButtonItem = popoverUserconfigurationAnchor
    vc.preferredContentSize = CGSize(width: 320, height: 240)

    present(vc, animated: true) {
      // Makes sure that the popover is dismissed also when tapping on one of
      // the other UIBarButtonItems.
      // ie. http://karmeye.com/2014/11/20/ios8-popovers-and-passthroughviews/
      vc.popoverPresentationController?.passthroughViews = nil
    }
  }
}

// MARK: - TPPReaderSettingsDelegate

extension TPPEPUBViewController: TPPReaderSettingsDelegate {
  
  internal func getUserSettings() -> UserSettings {
    return epubNavigator.userSettings
  }
  
  internal func updateUserSettingsStyle() {
    DispatchQueue.main.async {
      self.epubNavigator.updateUserSettingStyle()
    }
  }
  
  /// Synchronyze the UI appearance to the UserSettings.Appearance.
  ///
  /// - Parameter appearance: The appearance.
  internal func setUIColor(for appearance: UserProperty) {
    let colors = TPPAssociatedColors.colors(for: appearance)
    
    navigator.view.backgroundColor = colors.backgroundColor
    view.backgroundColor = colors.backgroundColor
    view.tintColor = colors.textColor
    navigationController?.navigationBar.setAppearance(TPPConfiguration.appearance(withBackgroundColor: colors.backgroundColor))
    navigationController?.navigationBar.forceUpdateAppearance(style: colors.navigationColor == .black ? .light : .dark)
    navigationController?.navigationBar.tintColor = colors.navigationColor
    tabBarController?.tabBar.tintColor = colors.navigationColor
  }
}


// MARK: - EPUBNavigatorDelegate

extension TPPEPUBViewController: EPUBNavigatorDelegate {
}

// MARK: - UIGestureRecognizerDelegate

extension TPPEPUBViewController: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }
}

// MARK: - UIPopoverPresentationControllerDelegate

extension TPPEPUBViewController: UIPopoverPresentationControllerDelegate {
  // Prevent the popOver to be presented fullscreen on iPhones.
  func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle
  {
    return .none
  }
}

