import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
import WebKit

class TPPEPUBViewController: TPPBaseReaderViewController {
  var popoverUserconfigurationAnchor: UIBarButtonItem?
  private let systemUserInterfaceStyle: UIUserInterfaceStyle
  private let searchButton = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(presentEPUBSearch))
  private var preferences: EPUBPreferences

  init(publication: Publication,
       book: TPPBook,
       initialLocation: Locator?,
       resourcesServer: HTTPServer,
       preferences: EPUBPreferences = .init(),
       forSample: Bool = false) throws {

    self.systemUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
    var updatedPreferences = preferences
    updatedPreferences.backgroundColor = ReadiumNavigator.Color.init(color: .black)
    updatedPreferences.textColor = ReadiumNavigator.Color.init(color: .white)
    updatedPreferences.fontFamily = .arial
    self.preferences = updatedPreferences

    let safeAreaInsets = UIApplication.shared.keyWindow?.safeAreaInsets ?? UIEdgeInsets()
    let overlayLabelInset = TPPBaseReaderViewController.overlayLabelMargin * 2
    let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
      .compact: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom)),
      .regular: (top: max(overlayLabelInset, safeAreaInsets.top), bottom: max(overlayLabelInset, safeAreaInsets.bottom))
    ]

    // Configuring the EPUB navigator with appropriate templates and actions
    var config = EPUBNavigatorViewController.Configuration(
      preferences: updatedPreferences,
      editingActions: EditingAction.defaultActions.appending(EditingAction(
        title: "Highlight",
        action: #selector(highlightSelection))),
      contentInset: contentInset,
      preloadPreviousPositionCount: 2,
      preloadNextPositionCount: 2,
      decorationTemplates: HTMLDecorationTemplate.defaultTemplates(),
      debugState: false
    )

    let navigator = try EPUBNavigatorViewController(
      publication: publication,
      initialLocation: initialLocation,
      config: config,
      httpServer: resourcesServer
    )

    super.init(navigator: navigator, publication: publication, book: book, forSample: forSample, initialLocation: initialLocation)

    setupViewHierarchy()
    setUIColor(for: preferences)
    log(.info, "TPPEPUBViewController initialized with publication: \(publication.metadata.title ?? "Unknown Title").")
  }

  private func setupViewHierarchy() {
    addChild(navigator)
    view.addSubview(navigator.view)

    navigator.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      navigator.view.topAnchor.constraint(equalTo: view.topAnchor),
      navigator.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      navigator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      navigator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])

    navigator.didMove(toParent: self)
  }

  var epubNavigator: EPUBNavigatorViewController {
    self.navigator as! EPUBNavigatorViewController
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    setUIColor(for: preferences)
    log(.info, "TPPEPUBViewController will appear. UI color set based on preferences.")
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    resetNavigationAppearance()
  }

  private func resetNavigationAppearance() {
    if let appearance = TPPConfiguration.defaultAppearance() {
      navigationController?.navigationBar.setAppearance(appearance)
      navigationController?.navigationBar.forceUpdateAppearance(style: systemUserInterfaceStyle)
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
    return buttons
  }

  @objc private func presentUserSettings() {
    let vc = TPPReaderSettingsVC.makeSwiftUIView(preferences: preferences, delegate: self)
    vc.modalPresentationStyle = .popover
    vc.popoverPresentationController?.delegate = self
    vc.popoverPresentationController?.barButtonItem = popoverUserconfigurationAnchor
    vc.preferredContentSize = CGSize(width: 320, height: 240)
    present(vc, animated: true) {
      vc.popoverPresentationController?.passthroughViews = nil
    }
  }

  @objc private func presentEPUBSearch() {
    let searchViewModel = EPUBSearchViewModel(publication: publication)
    searchViewModel.delegate = self
    let searchView = EPUBSearchView(viewModel: searchViewModel)
    let hostingController = UIHostingController(rootView: searchView)
    hostingController.modalPresentationStyle = .overFullScreen
    present(hostingController, animated: true)
  }

  @objc private func highlightSelection() {
    if let selection = epubNavigator.currentSelection {
//      let highlight = Highlight(bookId: book.bookID, locator: selection.locator, color: .yellow)
//      saveHighlight(highlight)
      epubNavigator.clearSelection()
    }
  }
}

// MARK: - TPPReaderSettingsDelegate
extension TPPEPUBViewController: TPPReaderSettingsDelegate {
  func getUserPreferences() -> EPUBPreferences {
    return preferences
  }

  func updateUserPreferencesStyle() {
    DispatchQueue.main.async {
      self.epubNavigator.submitPreferences(self.preferences)
    }
  }

  func setUIColor(for appearance: EPUBPreferences) {
    navigator.view.backgroundColor = appearance.backgroundColor?.uiColor
    view.backgroundColor = appearance.backgroundColor?.uiColor
    view.tintColor = appearance.textColor?.uiColor
  }
}

extension TPPEPUBViewController: EPUBSearchDelegate {
  func didSelect(location: ReadiumShared.Locator) {

    presentedViewController?.dismiss(animated: true) { [weak self] in
      guard let self = self else { return }

      Task {
        await self.navigator.go(to: location)

        if let decorableNavigator = self.navigator as? DecorableNavigator {
          var decorations: [Decoration] = []
          decorations.append(Decoration(
            id: "search",
            locator: location,
            style: .highlight(tint: .red)))
           decorableNavigator.apply(decorations: decorations, in: "search")
        }
      }
    }
  }
}

extension TPPEPUBViewController: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }
}

extension TPPEPUBViewController: UIPopoverPresentationControllerDelegate {}
