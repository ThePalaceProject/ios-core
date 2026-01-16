import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
import WebKit
import SwiftSoup

class TPPEPUBViewController: TPPBaseReaderViewController {
  var popoverUserconfigurationAnchor: UIBarButtonItem?
  private let systemUserInterfaceStyle: UIUserInterfaceStyle
  private let searchButton: UIBarButtonItem
  private var preferences: EPUBPreferences
  private var highlights: [Decoration] = []
  private var highlightGroup = "highlights"

  init(publication: Publication,
       book: TPPBook,
       initialLocation: Locator?,
       resourcesServer: HTTPServer,
       preferences: EPUBPreferences = TPPReaderPreferencesLoad(),
       forSample: Bool = false) throws {

    self.systemUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
    self.preferences = preferences

    self.searchButton = UIBarButtonItem(barButtonSystemItem: .search, target: nil, action: #selector(presentEPUBSearch))
    self.searchButton.accessibilityLabel = Strings.Generic.searchInBook
    
    // Use zero insets - letterbox container in base class handles spacing
    let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
      .compact: (top: 0, bottom: 0),
      .regular: (top: 0, bottom: 0)
    ]

    let config = EPUBNavigatorViewController.Configuration(
      preferences: preferences,
      editingActions: EditingAction.defaultActions.appending(EditingAction(
        title: "Highlight",
        action: #selector(highlightSelection))),
      contentInset: contentInset,
      decorationTemplates: HTMLDecorationTemplate.defaultTemplates(),
      debugState: true
    )

    let navigator = try EPUBNavigatorViewController(
      publication: publication,
      initialLocation: initialLocation,
      config: config,
      httpServer: resourcesServer
    )

    super.init(navigator: navigator, publication: publication, book: book, forSample: forSample, initialLocation: initialLocation)

    navigator.delegate = self
    self.searchButton.target = self
    setUIColor(for: preferences)
    log(.info, "TPPEPUBViewController initialized with publication: \(publication.metadata.title ?? "Unknown Title").")
  }

  var epubNavigator: EPUBNavigatorViewController {
    self.navigator as! EPUBNavigatorViewController
  }

  override func willMove(toParent parent: UIViewController?) {
    super.willMove(toParent: parent)
    navigationController?.navigationBar.barStyle = .default
    navigationController?.navigationBar.barTintColor = nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    
    observeDecorationInteractions(inGroup: highlightGroup) { event in
      self.handleHighlightInteraction(event)
    }
    
    epubNavigator.submitPreferences(preferences)
    setUIColor(for: preferences)
  }
  
  override func updateNavigationBar(animated: Bool = true) {
    super.updateNavigationBar(animated: animated)
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    setUIColor(for: preferences)
    log(.info, "TPPEPUBViewController will appear. UI color set based on preferences.")
    epubNavigator.submitPreferences(preferences)
    
    // Ensure tab bar is properly hidden on both iPhone and iPad
    if let tabBarController = tabBarController {
      tabBarController.tabBar.isHidden = true
      // On iPad, also ensure the tab bar is not translucent to prevent rendering issues
      if UIDevice.current.userInterfaceIdiom == .pad {
        tabBarController.tabBar.isTranslucent = false
      }
    }

    if navigationItem.leftBarButtonItem == nil {
       let backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: self, action: #selector(closeEPUB))
       backItem.accessibilityLabel = Strings.Generic.goBack
       navigationItem.leftBarButtonItem = backItem
     }

    navigationController?.navigationBar.isTranslucent = true
    
    navigationController?.setNavigationBarHidden(true, animated: false)
    navigationController?.setToolbarHidden(true, animated: false)
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    tabBarController?.tabBar.isHidden = true
  }
  
  @objc private func closeEPUB() {
    if let tabBarController = tabBarController {
      tabBarController.tabBar.isHidden = false
      tabBarController.tabBar.isTranslucent = true
    }
    
    NavigationCoordinatorHub.shared.coordinator?.pop()
  }
  
  override func viewSafeAreaInsetsDidChange() {
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    resetNavigationAppearance()
  }

  private func resetNavigationAppearance() {
    if let appearance = TPPConfiguration.defaultAppearance() {
      navigationController?.navigationBar.isTranslucent = false
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
          await decorableNavigator.applyDecorationsAsync(decorations, in: "search")
        }
      }
    }
  }
}

// MARK: - TPPReaderSettingsDelegate
extension TPPEPUBViewController: TPPReaderSettingsDelegate {
  func getUserPreferences() -> EPUBPreferences {
    return preferences
  }

  func updateUserPreferencesStyle(for appearance: EPUBPreferences) {
    self.preferences = appearance
    epubNavigator.submitPreferences(appearance)
    setUIColor(for: appearance)
  }

  func setUIColor(for appearance: EPUBPreferences) {
    let backgroundColor = appearance.backgroundColor?.uiColor ?? .black
    let textColor = appearance.textColor?.uiColor ?? .lightGray
    
    navigator.view.backgroundColor = backgroundColor
    view.backgroundColor = backgroundColor
    navigatorContainer?.backgroundColor = backgroundColor
    view.tintColor = textColor
    
    // Update label colors to match theme
    positionLabel.textColor = textColor.withAlphaComponent(0.7)
    bookTitleLabel.textColor = textColor.withAlphaComponent(0.7)
  }
}

extension TPPEPUBViewController: EPUBNavigatorDelegate {
  func navigator(_ navigator: Navigator, didFailWithError error: NavigatorError) {
    log(.error, "Navigator error: \(error.localizedDescription)")
  }
}

extension TPPEPUBViewController: UIPopoverPresentationControllerDelegate {
  func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
    return .none
  }
}

extension TPPEPUBViewController: DecorableNavigator {
  func apply(decorations: [Decoration], in group: String) {
    guard let navigator = navigator as? DecorableNavigator else { return }
    navigator.apply(decorations: decorations, in: group)
  }

  func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
    guard let navigator = navigator as? DecorableNavigator else { return false }
    return navigator.supports(decorationStyle: style)
  }

  func observeDecorationInteractions(inGroup group: String, onActivated: @escaping OnActivatedCallback) {
    guard let navigator = navigator as? DecorableNavigator else { return }
    navigator.observeDecorationInteractions(inGroup: group, onActivated: onActivated)
  }

  func addHighlight(for locator: Locator, color: UIColor = .yellow) {
    let highlight = Decoration(
      id: UUID().uuidString,
      locator: locator,
      style: .highlight(tint: color)
    )

    highlights.append(highlight)
    apply(decorations: highlights, in: highlightGroup)
  }

  func removeHighlight(_ id: String) {
    highlights.removeAll { $0.id == id }
    apply(decorations: highlights, in: highlightGroup)
  }

  @objc private func highlightSelection() {
    guard let selection = epubNavigator.currentSelection else { return }
    addHighlight(for: selection.locator, color: .yellow)
    epubNavigator.clearSelection()
  }

  private func handleHighlightInteraction(_ event: OnDecorationActivatedEvent) {}
}

public extension DecorableNavigator {
  func applyDecorationsAsync(_ decorations: [Decoration], in group: String) async {
    await MainActor.run {
      self.apply(decorations: decorations, in: group)
    }
  }
}

