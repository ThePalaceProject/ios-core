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
import WebKit
import ReadiumNavigator
import ReadiumShared
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
  var navigator: UIViewController & Navigator
  private var tocBarButton: UIBarButtonItem?
  private var bookmarkBarButton: UIBarButtonItem?
  private(set) var stackView: UIStackView!
  private(set) var navigatorContainer: UIView!
  private(set) lazy var positionLabel = UILabel()
  private(set) lazy var bookTitleLabel = UILabel()
  private var isShowingSample: Bool = false
  private var initialLocation: Locator?
  private var subscriptions: Set<AnyCancellable> = []
  private var currentLocationIsBookmarked: Bool {
    bookmarksBusinessLogic.currentLocation(in: navigator) != nil
  }

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
      publication: publication,
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
    
    // Ensure content extends under navigation bar without shifting when bar appears/disappears
    edgesForExtendedLayout = [.top, .bottom]
    extendedLayoutIncludesOpaqueBars = true

    navigationItem.rightBarButtonItems = makeNavigationBarButtons()
    updateNavigationBar(animated: false)
    setupStackView()

    addChild(navigator)
    
    // Create letterbox container
    navigatorContainer = UIView()
    navigatorContainer.backgroundColor = TPPConfiguration.backgroundColor()
    stackView.addArrangedSubview(navigatorContainer)
    
    // Inset navigator within container to create letterbox areas
    navigatorContainer.addSubview(navigator.view)
    navigator.view.translatesAutoresizingMaskIntoConstraints = false
    
    // IMPORTANT: Use FIXED offsets from container edges (not safe area) to prevent
    // content shifting when navigation bar appears/disappears.
    let fixedTopInset: CGFloat = 100.0  // Letterbox space for navbar + status bar
    let fixedBottomInset: CGFloat = 50.0  // Letterbox space for home indicator
    
    NSLayoutConstraint.activate([
      navigator.view.topAnchor.constraint(equalTo: navigatorContainer.topAnchor, constant: fixedTopInset),
      navigator.view.bottomAnchor.constraint(equalTo: navigatorContainer.bottomAnchor, constant: -fixedBottomInset),
      navigator.view.leadingAnchor.constraint(equalTo: navigatorContainer.leadingAnchor),
      navigator.view.trailingAnchor.constraint(equalTo: navigatorContainer.trailingAnchor)
    ])
    
    navigator.didMove(toParent: self)
    
    // Prevent navigator from using safe area insets - critical for Readium 3.3.0
    navigator.view.insetsLayoutMarginsFromSafeArea = false
    navigator.additionalSafeAreaInsets = .zero
    
    // Prevent scroll view and WKWebView content inset adjustment
    if let scrollView = navigator.view as? UIScrollView {
      scrollView.contentInsetAdjustmentBehavior = .never
    } else {
      // Check subviews for scroll views and web views (Readium uses WKWebView for EPUBs)
      navigator.view.subviews.forEach { subview in
        if let webView = subview as? WKWebView {
          webView.scrollView.contentInsetAdjustmentBehavior = .never
          webView.scrollView.contentInset = .zero
          webView.scrollView.scrollIndicatorInsets = .zero
        } else if let scrollView = subview as? UIScrollView {
          scrollView.contentInsetAdjustmentBehavior = .never
        }
      }
    }

    stackView.addArrangedSubview(accessibilityToolbar)
    accessibilityToolbar.accessibilityElementsHidden = true

    // Position label in the bottom letterbox area
    positionLabel.translatesAutoresizingMaskIntoConstraints = false
    positionLabel.font = .systemFont(ofSize: 12)
    positionLabel.textAlignment = .center
    positionLabel.lineBreakMode = .byTruncatingTail
    positionLabel.textColor = .lightGray
    navigatorContainer.addSubview(positionLabel)
    NSLayoutConstraint.activate([
      positionLabel.bottomAnchor.constraint(equalTo: navigatorContainer.bottomAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin),
      positionLabel.leftAnchor.constraint(equalTo: navigatorContainer.leftAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin),
      positionLabel.rightAnchor.constraint(equalTo: navigatorContainer.rightAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin),
      positionLabel.topAnchor.constraint(greaterThanOrEqualTo: navigator.view.bottomAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin / 2)
    ])

    // Book title label - positioned below status bar using safe area
    // PP-3398: Previously at 20px from container top, which overlapped the status bar
    // Using view's safe area (not container) so label moves with status bar but doesn't affect navigator
    bookTitleLabel.translatesAutoresizingMaskIntoConstraints = false
    bookTitleLabel.font = .systemFont(ofSize: 12)
    bookTitleLabel.textAlignment = .center
    bookTitleLabel.lineBreakMode = .byTruncatingTail
    bookTitleLabel.textColor = .lightGray
    view.addSubview(bookTitleLabel)  // Add to view, not navigatorContainer
    NSLayoutConstraint.activate([
      // Position below safe area (status bar) with small margin
      bookTitleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
      bookTitleLabel.leftAnchor.constraint(equalTo: view.leftAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin),
      bookTitleLabel.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin),
    ])

    // Accessibility
    updateViewsForVoiceOver(isRunning: UIAccessibility.isVoiceOverRunning)

    if let initialLocation = initialLocation {
      Task {
        await navigator.go(to: initialLocation)
      }
    }
  }

  private func setupStackView() {
    stackView = UIStackView(frame: .zero)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.distribution = .fill
    stackView.axis = .vertical
    view.addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: view.topAnchor),
      stackView.rightAnchor.constraint(equalTo: view.rightAnchor),
      stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stackView.leftAnchor.constraint(equalTo: view.leftAnchor)
    ])
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    
    // Continuously negate safe area insets to prevent Readium from responding
    navigator.additionalSafeAreaInsets = UIEdgeInsets(
      top: -view.safeAreaInsets.top,
      left: 0,
      bottom: -view.safeAreaInsets.bottom,
      right: 0
    )
  }
  
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    
    // Ensure scroll views never adjust for content insets
    configureScrollViewInsets()
  }
  
  private func configureScrollViewInsets() {
    if let scrollView = navigator.view as? UIScrollView {
      scrollView.contentInsetAdjustmentBehavior = .never
    } else {
      navigator.view.subviews.forEach { subview in
        configureScrollViewRecursively(subview)
      }
    }
  }
  
  private func configureScrollViewRecursively(_ view: UIView) {
    view.insetsLayoutMarginsFromSafeArea = false
    
    // Handle WKWebView specifically - this is what Readium uses for EPUB content
    if let webView = view as? WKWebView {
      webView.scrollView.contentInsetAdjustmentBehavior = .never
      webView.scrollView.contentInset = .zero
      webView.scrollView.scrollIndicatorInsets = .zero
    }
    
    if let scrollView = view as? UIScrollView {
      scrollView.contentInsetAdjustmentBehavior = .never
    }
    
    view.subviews.forEach { configureScrollViewRecursively($0) }
  }

  override func willMove(toParent parent: UIViewController?) {
    super.willMove(toParent: parent)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    accessibilityToolbar.accessibilityElementsHidden = false
    
    // Readium may create WKWebViews asynchronously, so reconfigure after appearing
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.configureScrollViewInsets()
    }
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
    bookmarkBtn.accessibilityLabel = currentLocationIsBookmarked ? Strings.TPPBaseReaderViewController.removeBookmark :  Strings.TPPBaseReaderViewController.addBookmark
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
    // Keep status bar visible on iPad to avoid safe area changes when navbar toggles
    if UIDevice.current.userInterfaceIdiom == .pad {
      return false
    }
    return navigationBarHidden
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

  private func addBookmark(at location: TPPBookmarkR3Location) {
    Task {
      guard let bookmark = await bookmarksBusinessLogic.addBookmark(location) else {
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
    toolbar.isHidden = !isVoiceOverRunning
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
    isVoiceOverRunning = isRunning
    updateNavigationBar()
    accessibilityToolbar.isHidden = !isRunning
    positionLabel.isHidden = isRunning
    bookTitleLabel.isHidden = isRunning

    // Adjust bottom inset for accessibility toolbar
    if let scrollView = (navigator.view as? UIScrollView) ?? navigator.view.subviews.compactMap({ $0 as? UIScrollView }).first {
      if isRunning {
        // Ensure layout is up to date to get correct toolbar height
        view.layoutIfNeeded()
        let toolbarHeight = accessibilityToolbar.frame.height
        scrollView.contentInset.bottom = toolbarHeight
        scrollView.scrollIndicatorInsets.bottom = toolbarHeight
      } else {
        scrollView.contentInset.bottom = 0
        scrollView.scrollIndicatorInsets.bottom = 0
      }
    }

    if isRunning {
      UIAccessibility.post(notification: .layoutChanged, argument: navigationController?.navigationBar)
    }
  }

  @objc private func goBackward() {
    Task {
      await navigator.goBackward(options: NavigatorGoOptions(animated: false))
      if let title = self.navigator.currentLocation?.title {
        UIAccessibility.post(notification: .announcement, argument: title)
      }
    }
  }

  @objc private func goForward() {
    Task {
      await navigator.goForward(options: NavigatorGoOptions(animated: false))
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
    Task {
      Log.info(#function, "R3 locator changed to: \(locator)")

      // Save location here only if VoiceOver is not running; it doesn't save exact location on page
      if !isVoiceOverRunning {
        lastReadPositionPoster.storeReadPosition(locator: locator)
      }

      positionLabel.text = await {
        var chapterTitle = ""
        if let title = locator.title {
          chapterTitle = " (\(title))"
        }

        var positions: [Locator] = []

        let result = await publication.positions()
        switch result {
        case .success(let locators):
          positions = locators
        case .failure(let error):
          moduleDelegate?.presentError(error, from: self)
        }

        if let position = locator.locations.position {
          return String(format: Strings.TPPBaseReaderViewController.pageOf, position) + "\(positions.count)" + chapterTitle
        } else if let progression = locator.locations.totalProgression {
          return "\(progression)%" + chapterTitle
        } else {
          return nil
        }
      }()

      bookTitleLabel.text = publication.metadata.title

      if let resourceIndex = publication.resourceIndex(forLocator: locator),
         let _ = bookmarksBusinessLogic.isBookmarkExisting(at: TPPBookmarkR3Location(resourceIndex: resourceIndex, locator: locator)) {
        updateBookmarkButton(withState: true)
      } else {
        updateBookmarkButton(withState: false)
      }
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

  func navigator(_ navigator: any ReadiumNavigator.Navigator, didFailToLoadResourceAt href: ReadiumShared.RelativeURL, withError error: ReadiumShared.ReadError) {
    moduleDelegate?.presentError(error, from: self)
  }
}

//------------------------------------------------------------------------------
// MARK: - VisualNavigatorDelegate

extension TPPBaseReaderViewController: VisualNavigatorDelegate {

  func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
    let viewport = navigator.view.bounds
    let thresholdRange = 0...(0.2 * viewport.width)

    Task {
      var moved = false
      if thresholdRange ~= point.x {
        moved = await navigator.goLeft(options: NavigatorGoOptions(animated: false))
      } else if thresholdRange ~= (viewport.maxX - point.x) {
        moved = await navigator.goRight(options: NavigatorGoOptions(animated: false))
      }

      if !moved {
        toggleNavigationBar()
      }
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

    Task {
      if let location = loc as? Locator {
        await navigator.go(to: location)
      }
    }
  }

  func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                   didSelectBookmark bookmark: TPPReadiumBookmark) {

    if shouldPresentAsPopover() {
      dismiss(animated: true)
    } else {
      navigationController?.popViewController(animated: true)
    }

    Task {
      let r3bookmark = bookmark.convertToR3(from: publication)
      if let locator = r3bookmark?.locator {
        await navigator.go(to: locator)
      }
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
