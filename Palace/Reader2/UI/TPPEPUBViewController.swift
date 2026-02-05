import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
import GameController

class TPPEPUBViewController: TPPBaseReaderViewController {
  var popoverUserconfigurationAnchor: UIBarButtonItem?
  private let systemUserInterfaceStyle: UIUserInterfaceStyle
  private let searchButton: UIBarButtonItem
  private var preferences: EPUBPreferences
  private var highlights: [Decoration] = []
  private var highlightGroup = "highlights"
  private var keyboardInput: GCKeyboardInput?
  private var keyboardConnectObserver: NSObjectProtocol?
  private var keyboardDisconnectObserver: NSObjectProtocol?
  private var isShiftPressed = false
  private lazy var keyboardNavigationHandler = KeyboardNavigationHandler(navigable: self)

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

    // MARK: - Readium Input Observers

    // DirectionalNavigationAdapter handles BOTH edge taps AND keyboard navigation.
    // Keyboard events arrive via Readium's JavaScript bridge (keyboard.js captures
    // keydown in WKWebView, calls preventDefault, forwards via messageHandlers).
    // This matches Readium's TestApp configuration.
    DirectionalNavigationAdapter(
      pointerPolicy: DirectionalNavigationAdapter.PointerPolicy(
        types: [.touch],
        edges: .horizontal,
        ignoreWhileScrolling: true,
        horizontalEdgeThresholdPercent: 0.2
      ),
      animatedTransition: true
    ).bind(to: navigator)

    // Readium key observer — handles keys NOT covered by DirectionalNavigationAdapter
    // (e.g. Escape for toolbar toggle). Arrow/space events are consumed by
    // DirectionalNavigationAdapter above (registered first = higher priority).
    navigator.addObserver(.key { [weak self] event in
      guard let self = self else { return false }
      return await self.keyboardNavigationHandler.handleKeyEvent(event)
    })

    // Center taps toggle toolbar, then reclaim first responder so
    // UIKeyCommands keep working (tapping WKWebView steals it).
    navigator.addObserver(.tap { [weak self] _ in
      self?.toggleNavigationBar()
      self?.claimFirstResponder()
      return true
    })

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

    // Configure accessibility for Full Keyboard Access (FKA) users.
    // FKA intercepts arrow keys at the system level for focus navigation.
    // Users can press Tab-Z to access these custom actions for page turning.
    configureAccessibilityActions()
  }

  // MARK: - Accessibility (Full Keyboard Access support)

  /// Configure accessibility custom actions for page turning.
  /// These appear in the Tab-Z menu when Full Keyboard Access is enabled,
  /// providing an alternative to arrow keys which FKA consumes.
  private func configureAccessibilityActions() {
    // Make the navigator view respond as a single accessible element
    // so FKA doesn't try to focus individual elements within the WKWebView.
    navigator.view.isAccessibilityElement = true
    navigator.view.accessibilityLabel = Strings.Generic.bookReader
    navigator.view.accessibilityTraits = .allowsDirectInteraction

    // Custom actions accessible via Tab-Z for FKA users
    let nextPageAction = UIAccessibilityCustomAction(
      name: Strings.Generic.nextPage,
      actionHandler: { [weak self] _ in
        guard let self = self else { return false }
        Task { @MainActor in
          _ = await self.navigator.goForward(options: NavigatorGoOptions(animated: true))
        }
        return true
      }
    )

    let previousPageAction = UIAccessibilityCustomAction(
      name: Strings.Generic.previousPage,
      actionHandler: { [weak self] _ in
        guard let self = self else { return false }
        Task { @MainActor in
          _ = await self.navigator.goBackward(options: NavigatorGoOptions(animated: true))
        }
        return true
      }
    )

    let toggleToolbarAction = UIAccessibilityCustomAction(
      name: Strings.Generic.toggleToolbar,
      actionHandler: { [weak self] _ in
        self?.toggleNavigationBar()
        return true
      }
    )

    navigator.view.accessibilityCustomActions = [nextPageAction, previousPageAction, toggleToolbarAction]
  }

  /// Reclaim first responder after each page load so UIKeyCommands stay active.
  /// WKWebView often reclaims first responder when it finishes rendering content.
  override func didChangeLocation(_ locator: Locator) {
    claimFirstResponder()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    tabBarController?.tabBar.isHidden = true
    startKeyboardInputMonitoring()
    // Readium's InputObservableViewController.viewDidAppear also calls
    // becomeFirstResponder(). Reclaim after a short delay so our UIKeyCommands
    // take priority, and again after WKWebView finishes async content loading.
    claimFirstResponder()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.claimFirstResponder()
    }
  }

  // MARK: - First Responder & Focus Control

  /// Claim first responder so UIKeyCommands are matched on THIS VC before
  /// WKWebView's web-content process can consume arrow key events.
  private func claimFirstResponder() {
    if !isFirstResponder {
      becomeFirstResponder()
    }
  }

  /// Refuse to give up first responder. WKWebView aggressively reclaims it
  /// after content loads, stealing it from our VC. When WKWebView is first
  /// responder, the iPadOS/iOS focus engine consumes arrow keys before
  /// UIKeyCommand matching. By staying first responder, our UIKeyCommands
  /// with wantsPriorityOverSystemBehavior fire BEFORE the focus engine.
  @discardableResult
  override func resignFirstResponder() -> Bool {
    return false
  }

  /// Block FKA from moving focus between Readium's internal WKWebViews.
  override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
    return false
  }

  // MARK: - UIKeyCommand (Primary Keyboard Path)

  /// UIKeyCommand with `wantsPriorityOverSystemBehavior` intercepts arrow keys
  /// BEFORE the focus engine consumes them. This is the only reliable path on
  /// iPadOS where the focus system eats arrow/space events.
  private static let readerKeyCommands: [UIKeyCommand] = {
    let commands = [
      UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyCommandGoBackward)),
      UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyCommandGoForward)),
      UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyCommandGoForward)),
      UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(keyCommandGoBackward)),
      UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(keyCommandToggleUI)),
      UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(keyCommandGoBackward)),
      UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(keyCommandGoForward)),
    ]
    commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
    return commands
  }()

  override var keyCommands: [UIKeyCommand]? {
    return Self.readerKeyCommands
  }

  @objc private func keyCommandGoBackward() {
    Task { @MainActor in
      await keyboardNavigationHandler.handleCommand(.goBackward, via: self)
    }
  }

  @objc private func keyCommandGoForward() {
    Task { @MainActor in
      await keyboardNavigationHandler.handleCommand(.goForward, via: self)
    }
  }

  @objc private func keyCommandToggleUI() {
    Task { @MainActor in
      await keyboardNavigationHandler.handleCommand(.toggleUI, via: self)
    }
  }

  // MARK: - GCKeyboard Monitoring

  private func startKeyboardInputMonitoring() {
    keyboardConnectObserver = NotificationCenter.default.addObserver(
      forName: .GCKeyboardDidConnect,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.configureKeyboardInput()
    }

    keyboardDisconnectObserver = NotificationCenter.default.addObserver(
      forName: .GCKeyboardDidDisconnect,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.keyboardInput?.keyChangedHandler = nil
      self?.keyboardInput = nil
    }

    configureKeyboardInput()
  }

  private func stopKeyboardInputMonitoring() {
    keyboardInput?.keyChangedHandler = nil
    keyboardInput = nil
    if let observer = keyboardConnectObserver {
      NotificationCenter.default.removeObserver(observer)
      keyboardConnectObserver = nil
    }
    if let observer = keyboardDisconnectObserver {
      NotificationCenter.default.removeObserver(observer)
      keyboardDisconnectObserver = nil
    }
  }

  private func configureKeyboardInput() {
    guard let input = GCKeyboard.coalesced?.keyboardInput else { return }
    keyboardInput = input
    input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
      guard let self = self else { return }
      if keyCode == .leftShift || keyCode == .rightShift {
        self.isShiftPressed = pressed
        return
      }
      guard pressed else { return }
      if let command = KeyboardInputMapper.command(for: keyCode, isShiftPressed: self.isShiftPressed) {
        Task { @MainActor in
          await self.keyboardNavigationHandler.handleCommand(command, via: self)
        }
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    setUIColor(for: preferences)
    log(.info, "TPPEPUBViewController will appear. UI color set based on preferences.")
    epubNavigator.submitPreferences(preferences)

    // Ensure tab bar is properly hidden on both iPhone and iPad
    if let tabBarController = tabBarController {
      tabBarController.tabBar.isHidden = true
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
    stopKeyboardInputMonitoring()
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

// MARK: - KeyboardNavigable

extension TPPEPUBViewController: KeyboardNavigable {
  var isToolbarHidden: Bool {
    navigationController?.isNavigationBarHidden ?? true
  }

  func toggleToolbar() {
    toggleNavigationBar()
  }

  func navigateLeft() async -> Bool {
    await navigator.goBackward(options: NavigatorGoOptions(animated: false))
  }

  func navigateRight() async -> Bool {
    await navigator.goForward(options: NavigatorGoOptions(animated: false))
  }

  func navigateForward() async -> Bool {
    await navigator.goForward(options: NavigatorGoOptions(animated: false))
  }
}

// MARK: - KeyboardInputMapper

enum KeyboardInputMapper {
  static func command(for keyCode: GCKeyCode, isShiftPressed: Bool) -> TPPBaseReaderViewController.ReaderKeyboardCommand? {
    switch keyCode {
    case .leftArrow, .pageUp:
      return .goBackward
    case .rightArrow, .pageDown:
      return .goForward
    case .spacebar:
      if isShiftPressed {
        return .goBackward
      }
      return .goForward
    case .escape:
      return .toggleUI
    default:
      return nil
    }
  }
}

// MARK: - UIPopoverPresentationControllerDelegate
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
