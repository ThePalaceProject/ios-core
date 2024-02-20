//
//  ReaderViewController.swift
//  Created by Mickaël Menu on 07.03.19.
//
//  Copyright 2019 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import SafariServices
import UIKit
import R2Navigator
import R2Shared
import Combine

/// This class is meant to be subclassed by each publication format view controller. It contains the shared behavior, eg. navigation bar toggling.
class TPPBaseReaderViewController: UIViewController, Loggable {
  typealias DisplayStrings = Strings.TPPBaseReaderViewController

  private static let bookmarkOnImageName = "BookmarkOn"
  private static let bookmarkOffImageName = "BookmarkOff"

  // Side margins for long labels
  static let overlayLabelMargin: CGFloat = 20
  
  // TODO: SIMPLY-2656 See if we still need this.
  weak var moduleDelegate: ModuleDelegate?

  // Models and business logic references
  let publication: Publication
  private let bookmarksBusinessLogic: TPPReaderBookmarksBusinessLogic
  private let lastReadPositionPoster: TPPLastReadPositionPoster

  // UI
  let navigator: UIViewController & Navigator
  private var tocBarButton: UIBarButtonItem?
  private var bookmarkBarButton: UIBarButtonItem?
  private(set) var stackView: UIStackView!
  private lazy var positionLabel = UILabel()
  private lazy var bookTitleLabel = UILabel()
  private var isShowingSample: Bool = false
  private var initialLocation: Locator?
  private var subscriptions: Set<AnyCancellable> = []
  
  // MARK: - Lifecycle

  /// Designated initializer.
  /// - Parameters:
  ///   - navigator: VC that is capable of navigating the publication.
  ///   - publication: The R2 model for a publication.
  ///   - book: The SimplyE model for a book.
  ///   - drm: Information about the DRM associated with the publication.
  init(navigator: UIViewController & Navigator,
       publication: Publication,
       book: TPPBook,
       forSample: Bool = false,
       initialLocation: Locator? = nil) {

    self.navigator = navigator
    self.publication = publication
    self.isShowingSample = forSample
    self.initialLocation = initialLocation
    
    lastReadPositionPoster = TPPLastReadPositionPoster(
      book: book,
      r2Publication: publication,
      bookRegistryProvider: TPPBookRegistry.shared)

    bookmarksBusinessLogic = TPPReaderBookmarksBusinessLogic(
      book: book,
      r2Publication: publication,
      drmDeviceID: TPPUserAccount.sharedAccount().deviceID,
      bookRegistryProvider: TPPBookRegistry.shared,
      currentLibraryAccountProvider: AccountsManager.shared)

    bookmarksBusinessLogic.syncBookmarks { (_, _) in }

    super.init(nibName: nil, bundle: nil)

    NotificationCenter.default.addObserver(self, selector: #selector(voiceOverStatusDidChange), name: Notification.Name(UIAccessibility.voiceOverStatusDidChangeNotification.rawValue), object: nil)

  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - UIViewController

  override func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = TPPConfiguration.backgroundColor()

    navigationItem.rightBarButtonItems = makeNavigationBarButtons()
    updateNavigationBar(animated: false)

    stackView = UIStackView(frame: view.bounds)
    stackView.distribution = .fill
    stackView.axis = .vertical
    view.addSubview(stackView)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    let topConstraint = stackView.topAnchor.constraint(equalTo: view.topAnchor)
    // `accessibilityTopMargin` takes precedence when VoiceOver is enabled.
    topConstraint.priority = .defaultHigh
    NSLayoutConstraint.activate([
      topConstraint,
      stackView.rightAnchor.constraint(equalTo: view.rightAnchor),
      stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stackView.leftAnchor.constraint(equalTo: view.leftAnchor)
    ])

    addChild(navigator)
    stackView.addArrangedSubview(navigator.view)
    navigator.didMove(toParent: self)

    stackView.addArrangedSubview(accessibilityToolbar)
    accessibilityToolbar.accessibilityElementsHidden = true

    positionLabel.translatesAutoresizingMaskIntoConstraints = false
    positionLabel.font = .systemFont(ofSize: 12)
    positionLabel.textAlignment = .center
    positionLabel.lineBreakMode = .byTruncatingTail
    positionLabel.textColor = .darkGray
    view.addSubview(positionLabel)
    NSLayoutConstraint.activate([
      positionLabel.bottomAnchor.constraint(equalTo: navigator.view.bottomAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin),
      positionLabel.leftAnchor.constraint(equalTo: navigator.view.leftAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin),
      positionLabel.rightAnchor.constraint(equalTo: navigator.view.rightAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin)
    ])
    
    bookTitleLabel.translatesAutoresizingMaskIntoConstraints = false
    bookTitleLabel.font = .systemFont(ofSize: 12)
    bookTitleLabel.textAlignment = .center
    bookTitleLabel.lineBreakMode = .byTruncatingTail
    bookTitleLabel.textColor = .darkGray
    view.addSubview(bookTitleLabel)
    var layoutConstraints: [NSLayoutConstraint] = [
      bookTitleLabel.leftAnchor.constraint(equalTo: navigator.view.leftAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin),
      bookTitleLabel.rightAnchor.constraint(equalTo: navigator.view.rightAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin)
    ]
    if #available(iOS 11.0, *) {
      layoutConstraints.append(bookTitleLabel.topAnchor.constraint(equalTo: navigator.view.safeAreaLayoutGuide.topAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin / 2))
    } else {
      layoutConstraints.append(bookTitleLabel.topAnchor.constraint(equalTo: navigator.view.topAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin))
    }
    NSLayoutConstraint.activate(layoutConstraints)
    
    // Accessibility
    updateViewsForVoiceOver(isRunning: UIAccessibility.isVoiceOverRunning)
    
  }

  override func willMove(toParent parent: UIViewController?) {
    super.willMove(toParent: parent)
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    accessibilityToolbar.accessibilityElementsHidden = false
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if let locator = navigator.currentLocation {
      lastReadPositionPoster.storeReadPosition(locator: locator)
    }
  }

  
  // MARK: - Navigation bar

  private var navigationBarHidden: Bool = true {
    didSet {
      updateNavigationBar()
    }
  }

  func makeNavigationBarButtons() -> [UIBarButtonItem] {
    var buttons: [UIBarButtonItem] = []

    let img = UIImage(named: TPPBaseReaderViewController.bookmarkOffImageName)
    let bookmarkBtn = UIBarButtonItem(image: img,
                                      style: .plain,
                                      target: self,
                                      action: #selector(toggleBookmark))
    bookmarkBtn.accessibilityLabel = Strings.Accessibility.toggleBookmark
    let tocButton = UIBarButtonItem(image: UIImage(named: "TOC"),
                                    style: .plain,
                                    target: self,
                                    action: #selector(presentPositionsVC))
    tocButton.accessibilityLabel = Strings.Accessibility.viewBookmarksAndTocButton
    
    if !isShowingSample {
      buttons.append(bookmarkBtn)
    }

    buttons.append(tocButton)
    tocBarButton = tocButton
    bookmarkBarButton = bookmarkBtn
    updateBookmarkButton(withState: false)

    return buttons
  }

  private func updateBookmarkButton(withState isOn: Bool) {
    guard let btn = bookmarkBarButton else {
      return
    }

    if isOn {
      btn.image = UIImage(named: TPPBaseReaderViewController.bookmarkOnImageName)
      btn.accessibilityLabel = DisplayStrings.removeBookmark
    } else {
      btn.image = UIImage(named: TPPBaseReaderViewController.bookmarkOffImageName)
      btn.accessibilityLabel = DisplayStrings.addBookmark
    }
  }

  func toggleNavigationBar() {
    navigationBarHidden = !navigationBarHidden
    bookTitleLabel.isHidden = UIAccessibility.isVoiceOverRunning || !navigationBarHidden
  }

  func updateNavigationBar(animated: Bool = true) {
    let hidden = navigationBarHidden && !UIAccessibility.isVoiceOverRunning
    navigationController?.setNavigationBarHidden(hidden, animated: animated)
    setNeedsStatusBarAppearanceUpdate()
  }

  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
    return .slide
  }

  override var prefersStatusBarHidden: Bool {
    return navigationBarHidden && !UIAccessibility.isVoiceOverRunning
  }

  //----------------------------------------------------------------------------
  // MARK: - TOC / Bookmarks

  private func shouldPresentAsPopover() -> Bool {
    return UIDevice.current.userInterfaceIdiom == .pad
  }

  @objc func presentPositionsVC() {
    let currentLocation = navigator.currentLocation
    let positionsVC = TPPReaderPositionsVC.newInstance()

    positionsVC.tocBusinessLogic = TPPReaderTOCBusinessLogic(r2Publication: publication,
                                                              currentLocation: currentLocation)
    positionsVC.bookmarksBusinessLogic = bookmarksBusinessLogic
    positionsVC.delegate = self

    if shouldPresentAsPopover() {
      positionsVC.modalPresentationStyle = .popover
      positionsVC.popoverPresentationController?.barButtonItem = tocBarButton
      present(positionsVC, animated: true) {
        // Makes sure that the popover is dismissed also when tapping on one of
        // the other UIBarButtonItems.
        // ie. http://karmeye.com/2014/11/20/ios8-popovers-and-passthroughviews
        positionsVC.popoverPresentationController?.passthroughViews = nil
      }
    } else {
      navigationController?.pushViewController(positionsVC, animated: true)
    }
  }

  @objc func toggleBookmark() {
    guard let loc = bookmarksBusinessLogic.currentLocation(in: navigator) else {
      return
    }

    if let bookmark = bookmarksBusinessLogic.isBookmarkExisting(at: loc) {
      deleteBookmark(bookmark)
    } else {
      addBookmark(at: loc)
    }
  }

  private func addBookmark(at location: TPPBookmarkR2Location) {
    guard let bookmark = bookmarksBusinessLogic.addBookmark(location) else {
      let alert = TPPAlertUtils.alert(title: "Bookmarking Error",
                                       message: "A bookmark could not be created on the current page.")
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert,
                                                    viewController: self,
                                                    animated: true,
                                                    completion: nil)
      return
    }

    Log.info(#file, "Created bookmark: \(bookmark)")

    updateBookmarkButton(withState: true)
  }

  private func deleteBookmark(_ bookmark: TPPReadiumBookmark) {
    bookmarksBusinessLogic.deleteBookmark(bookmark)
    didDeleteBookmark(bookmark)
  }

  private func didDeleteBookmark(_ bookmark: TPPReadiumBookmark) {
    // at this point the bookmark has already been removed, so we just need
    // to verify that the user is not at the same location of another bookmark,
    // in which case the bookmark icon will be lit up and should stay lit up.
    if
      let loc = bookmarksBusinessLogic.currentLocation(in: navigator),
      bookmarksBusinessLogic.isBookmarkExisting(at: loc) == nil {

      updateBookmarkButton(withState: false)
    }
  }

  //----------------------------------------------------------------------------
  // MARK: - Accessibility

  /// Constraint used to shift the content under the navigation bar, since it is always visible when VoiceOver is running.
  private lazy var accessibilityTopMargin: NSLayoutConstraint = {
    let topAnchor: NSLayoutYAxisAnchor = {
      if #available(iOS 11.0, *) {
        return self.view.safeAreaLayoutGuide.topAnchor
      } else {
        return self.topLayoutGuide.bottomAnchor
      }
    }()
    return self.stackView.topAnchor.constraint(equalTo: topAnchor)
  }()

  private lazy var accessibilityToolbar: UIToolbar = {
    func makeItem(_ item: UIBarButtonItem.SystemItem, label: String? = nil, action: UIKit.Selector? = nil) -> UIBarButtonItem {
      let button = UIBarButtonItem(barButtonSystemItem: item, target: (action != nil) ? self : nil, action: action)
      button.accessibilityLabel = label
      return button
    }
        
    let toolbar = UIToolbar(frame: .zero)
    let forwardButton = makeItem(.fastForward, label: DisplayStrings.nextChapter, action: #selector(goForward))
    let backButton = makeItem(.rewind, label: DisplayStrings.previousChapter, action: #selector(goBackward))
    
    toolbar.items = [
      backButton,
      makeItem(.flexibleSpace),
      forwardButton,
    ]
    toolbar.isHidden = !UIAccessibility.isVoiceOverRunning
    toolbar.tintColor = UIColor.black
    return toolbar
  }()
    
  private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

  @objc func voiceOverStatusDidChange() {
    let isRunning = UIAccessibility.isVoiceOverRunning
    // Avoids excessive settings refresh when the status didn't change.
    guard isVoiceOverRunning != isRunning else {
      return
    }
    updateViewsForVoiceOver(isRunning: isRunning)
  }
  
  func updateViewsForVoiceOver(isRunning: Bool) {
    updateNavigationBar()
    isVoiceOverRunning = isRunning
    accessibilityTopMargin.isActive = isRunning
    accessibilityToolbar.isHidden = !isRunning
    positionLabel.isHidden = isRunning
    bookTitleLabel.isHidden = isRunning
    if isRunning {
      UIAccessibility.post(notification: .layoutChanged, argument: navigationController?.navigationBar)
    }
  }

  @objc private func goBackward() {
    navigator.goBackward(animated: false) {
      if let title = self.navigator.currentLocation?.title {
        UIAccessibility.post(notification: .announcement, argument: title)
      }
    }
  }

  @objc private func goForward() {
    navigator.goForward(animated: false) {
      if let title = self.navigator.currentLocation?.title {
        UIAccessibility.post(notification: .announcement, argument: title)
      }
    }
  }

}

//------------------------------------------------------------------------------
// MARK: - NavigatorDelegate

extension TPPBaseReaderViewController: NavigatorDelegate {

  func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
    Log.info(#function, "R2 locator changed to: \(locator)")

    // Save location here only if VoiceOver is not running; it doesn't save exact location on page
    if !isVoiceOverRunning {
      lastReadPositionPoster.storeReadPosition(locator: locator)
    }

    positionLabel.text = {
      var chapterTitle = ""
      if let title = locator.title {
        chapterTitle = " (\(title))"
      }
      
      if let position = locator.locations.position {
        return String(format: Strings.TPPBaseReaderViewController.pageOf, position) + "\(publication.positions.count)" + chapterTitle
      } else if let progression = locator.locations.totalProgression {
        return "\(progression)%" + chapterTitle
      } else {
        return nil
      }
    }()
    
    bookTitleLabel.text = publication.metadata.title

    if let resourceIndex = publication.resourceIndex(forLocator: locator),
      let _ = bookmarksBusinessLogic.isBookmarkExisting(at: TPPBookmarkR2Location(resourceIndex: resourceIndex, locator: locator)) {
      updateBookmarkButton(withState: true)
    } else {
      updateBookmarkButton(withState: false)
    }
  }

  func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
    // SFSafariViewController crashes when given an URL without an HTTP scheme.
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      return
    }
    present(SFSafariViewController(url: url), animated: true)
  }

  func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
    moduleDelegate?.presentError(error, from: self)
  }

}

//------------------------------------------------------------------------------
// MARK: - VisualNavigatorDelegate

extension TPPBaseReaderViewController: VisualNavigatorDelegate {

  func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
    let viewport = navigator.view.bounds
    // Skips to previous/next pages if the tap is on the content edges.
    let thresholdRange = 0...(0.2 * viewport.width)
    var moved = false
    if thresholdRange ~= point.x {
      moved = navigator.goLeft(animated: false)
    } else if thresholdRange ~= (viewport.maxX - point.x) {
      moved = navigator.goRight(animated: false)
    }

    if !moved {
      toggleNavigationBar()
    }
  }

}

//------------------------------------------------------------------------------
// MARK: - TPPReaderPositionsDelegate

extension TPPBaseReaderViewController: TPPReaderPositionsDelegate {
  func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectTOCLocation loc: Any) {
    if shouldPresentAsPopover() {
      positionsVC.dismiss(animated: true)
    } else {
      navigationController?.popViewController(animated: true)
    }

    if let location = loc as? Locator {
      navigator.go(to: location)
    }
  }

  func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                   didSelectBookmark bookmark: TPPReadiumBookmark) {

    if shouldPresentAsPopover() {
      dismiss(animated: true)
    } else {
      navigationController?.popViewController(animated: true)
    }

    let r2bookmark = bookmark.convertToR2(from: publication)
    if let locator = r2bookmark?.locator {
      navigator.go(to: locator)
    }
  }

  func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                   didDeleteBookmark bookmark: TPPReadiumBookmark) {
    didDeleteBookmark(bookmark)
  }

  func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                   didRequestSyncBookmarksWithCompletion completion: @escaping (_ success: Bool, _ bookmarks: [TPPReadiumBookmark]) -> Void) {
    bookmarksBusinessLogic.syncBookmarks(completion: completion)
  }
}
