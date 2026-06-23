import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
import GameController
import PalaceLogging

class TPPEPUBViewController: TPPBaseReaderViewController {
    /// Tap handling is performed by Readium's input observer system:
    /// DirectionalNavigationAdapter for edge taps, .tap observer for center taps.
    /// Skips the legacy VisualNavigatorDelegate.didTapAt path to prevent
    /// double-toggling the toolbar (Readium fires both paths for every tap).
    override var usesInputObserversForTapHandling: Bool { true }

    var popoverUserconfigurationAnchor: UIBarButtonItem?
    private let systemUserInterfaceStyle: UIUserInterfaceStyle
    private let searchButton: UIBarButtonItem
    private var preferences: EPUBPreferences
    private let navigationHub: NavigationCoordinatorHub
    private var highlights: [Decoration] = []
    private var highlightGroup = "highlights"
    private var keyboardInput: GCKeyboardInput?
    private var keyboardConnectObserver: NSObjectProtocol?
    private var keyboardDisconnectObserver: NSObjectProtocol?
    private var isShiftPressed = false
    private lazy var keyboardNavigationHandler = KeyboardNavigationHandler(navigable: self)
    private var lastChapterHREF: String?

    /// The location the EPUB navigator's CONSTRUCTOR should restore to.
    ///
    /// EXACTLY ONE restore must reach the navigator. The post-first-paint gate
    /// (`ReaderInitialLocationNavigator`, fed via `super.init(initialLocation:)`)
    /// is the single restore authority — it `go(to:)`s the saved location once
    /// the WKWebView has reported first paint (`signalReady()` from
    /// `viewDidAppear`). If the navigator's `EPUBNavigatorViewController`
    /// constructor ALSO restores (non-nil `initialLocation:`), the saved location
    /// is applied during first paint and then AGAIN by the gate mid-layout →
    /// Readium "Failed to determine navigation direction for scroll" → WebContent
    /// teardown → the reader bounces back to My Books. (3.2.0 reading-resume
    /// regression: PR #981 added the gate but left the constructor restore in
    /// place.) So the constructor restore is always nil — the gate owns restore.
    static func navigatorConstructorInitialLocation(forSavedLocation savedLocation: Locator?) -> Locator? {
        // Always nil — the post-first-paint gate is the SINGLE restore authority.
        // (`savedLocation` is intentionally ignored; the navigator opens at its
        // natural start and the gate restores once the WKWebView is ready.)
        nil
    }

    init(publication: Publication,
         book: TPPBook,
         initialLocation: Locator?,
         preferences: EPUBPreferences = TPPReaderPreferencesLoad(),
         forSample: Bool = false,
         navigationHub: NavigationCoordinatorHub = AppContainer.production().navigationCoordinatorHub) throws {

        self.systemUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
        self.preferences = preferences
        self.navigationHub = navigationHub

        self.searchButton = UIBarButtonItem(barButtonSystemItem: .search, target: nil, action: #selector(presentEPUBSearch))
        self.searchButton.accessibilityLabel = Strings.Generic.searchInBook

        // Use zero insets - letterbox container in base class handles spacing
        let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
            .compact: (top: 0, bottom: 0),
            .regular: (top: 0, bottom: 0)
        ]

        // PP-4297: gate the system text-selection menu on the per-book
        // DRM-protected flag. DRM titles get an empty action list (no
        // long-press menu); non-DRM titles get Readium's defaults plus the
        // Palace Highlight action.
        let highlight = EditingAction(title: "Highlight",
                                      action: #selector(highlightSelection))
        let editingActions = ReaderEditingActions.resolve(
            for: book,
            isSample: forSample,
            appending: [highlight]
        )

        let config = EPUBNavigatorViewController.Configuration(
            preferences: preferences,
            editingActions: editingActions,
            contentInset: contentInset,
            decorationTemplates: HTMLDecorationTemplate.defaultTemplates(),
            debugState: true
        )

        // Readium 3.8.0+: the EPUB navigator serves publication resources via
        // an internal custom URL-scheme handler and no longer needs an HTTP
        // server. The `httpServer:` init is deprecated; use the no-server init.
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: Self.navigatorConstructorInitialLocation(forSavedLocation: initialLocation),
            config: config
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
        guard let epub = self.navigator as? EPUBNavigatorViewController else {
            fatalError("TPPEPUBViewController.navigator must be an EPUBNavigatorViewController")
        }
        return epub
    }

    /// Print page-list mapping for the "Where am I?" position report (PP-4527).
    /// Reuses the same layer as the nav-110 page navigation UI.
    private lazy var pageListBusinessLogic = TPPReaderPageListBusinessLogic(publication: publication)

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
        // "Where am I?" position report (DAISY nav-310, PP-4527): a VoiceOver
        // affordance that re-orients a non-visual reader without moving focus or
        // reading position. Exposed to both VoiceOver and FKA users; never a
        // visible control.
        let whereAmIAction = makeWhereAmIAction()

        if UIAccessibility.isVoiceOverRunning {
            // Let VoiceOver access the underlying WKWebView content directly. A
            // custom ACTION on this container is NOT reachable while VoiceOver
            // focuses web content (the PP-4527 bug), but custom ROTORS on the
            // container ARE reachable — so the reader affordances are exposed as
            // rotors, not actions. The keyboard (FKA) branch below still uses
            // whereAmIAction (Tab-Z reaches container custom actions).
            navigator.view.isAccessibilityElement = false
            navigator.view.accessibilityLabel = nil
            navigator.view.accessibilityCustomActions = nil

            // "Where am I?" position report (PP-4527, DAISY nav-310) as a custom
            // rotor — always available to VoiceOver readers. Block-by-block
            // navigation (PP-4533, reading-810) as a second rotor, gated on the
            // customRotorActionsEnabled preference (default on).
            var rotors: [UIAccessibilityCustomRotor] = [makeWhereAmIRotor()]
            if Self.customRotorActionsEnabled {
                rotors.append(makeBlockRotor())
            }
            navigator.view.accessibilityCustomRotors = rotors
            return
        }

        // Don't mark the navigator view as isAccessibilityElement — doing so
        // causes UIKit to treat it as an opaque leaf, swallowing touch events
        // before Readium's InputObservableViewController can receive them.
        // Custom actions still appear in FKA's Tab-Z menu without it.
        navigator.view.isAccessibilityElement = false

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

        navigator.view.accessibilityCustomActions = [nextPageAction, previousPageAction, toggleToolbarAction, whereAmIAction]
    }

    /// The "Where am I?" custom action. Activating it reports the current
    /// position via a VoiceOver announcement and returns immediately — it never
    /// calls `navigator.go(...)`, so focus and reading position are unchanged.
    private func makeWhereAmIAction() -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(
            name: Strings.TPPBaseReaderViewController.whereAmI,
            actionHandler: { [weak self] _ in
                self?.announceCurrentPosition()
                return true
            }
        )
    }

    /// A VoiceOver custom rotor that announces the current reading position
    /// without moving focus (PP-4527, DAISY nav-310). Selecting the "Where am I?"
    /// rotor and swiping reports the position via `announceCurrentPosition()`. A
    /// rotor is used (not a custom action) because a custom action on the
    /// WKWebView-hosting container is unreachable while VoiceOver focuses web
    /// content, whereas container rotors ARE reachable.
    private func makeWhereAmIRotor() -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(
            name: Strings.TPPBaseReaderViewController.whereAmI
        ) { [weak self] _ in
            self?.announceCurrentPosition()
            // One-shot trigger: the announcement is the payload; focus unchanged.
            return nil
        }
    }

    /// Build the position report from the current location and speak it via a
    /// VoiceOver announcement. Reports section + print page + percentage when
    /// available; a title with no page-list still reports section + percentage
    /// (nav-310 AC: the absence of a page number does not error).
    private func announceCurrentPosition() {
        let locator = navigator.currentLocation
        Task { @MainActor in
            var pageLabel: String?
            if let locator {
                pageLabel = await self.pageListBusinessLogic.currentPageLabel(for: locator)
            }
            let report = TPPReaderPositionReport.announcement(
                section: locator?.title,
                pageLabel: pageLabel,
                totalProgression: locator?.locations.totalProgression
            )
            UIAccessibility.post(notification: .announcement, argument: report)
        }
    }

    /// Annotate inline EPUB footnote elements (`doc-noteref` / `doc-footnote` /
    /// `doc-backlink`) in the rendered WKWebView with VoiceOver `aria-label`s so a
    /// non-visual reader knows a link is a note reference, hears the note, and can
    /// return to the reference (DAISY reading-420, PP-4531). Additive and
    /// idempotent; runs after the chapter has had a moment to render and bails if
    /// the chapter changed again in the meantime.
    private func annotateFootnotesForVoiceOver() {
        let href = lastChapterHREF
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard self.lastChapterHREF == href else { return }
            let result = await self.epubNavigator.evaluateJavaScript(
                TPPReaderFootnoteAccessibility.annotationJavaScript()
            )
            // PP-4531 observability: the injected aria-labels live in the Readium
            // WKWebView's web-AX, which host-AX / simdrive CANNOT inspect on the
            // simulator (verified 2026-06-23). Emit a log of the labelled-element
            // count + the VoiceOver state so the injection is verifiable
            // end-to-end via log capture (CI / host-AX), since neither the DOM
            // labels nor VoiceOver focus-speech surface to the host AX bridge.
            let value = try? result.get()
            let labelled = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
            Log.info(#file, "PP-4531 injected aria-labels on \(labelled) noteref/footnote/backlink elements, VoiceOver=\(UIAccessibility.isVoiceOverRunning)")
        }
    }

    /// Mark the logical block elements (paragraphs, headings, list items, quotes …)
    /// in the rendered WKWebView as atomic VoiceOver stops so a non-visual reader
    /// can step through content one block at a time via the "Blocks" rotor (DAISY
    /// reading-810, PP-4533). Additive and idempotent; runs after the chapter has
    /// had a moment to render and bails if the chapter changed again in the
    /// meantime. Mirrors `annotateFootnotesForVoiceOver()` from PP-4531.
    private func annotateBlocksForVoiceOver() {
        let href = lastChapterHREF
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard self.lastChapterHREF == href else { return }
            let result = await self.epubNavigator.evaluateJavaScript(
                TPPReaderBlockNavigation.annotationJavaScript()
            )
            // PP-4533 observability: the injected block marks live in the Readium
            // WKWebView's web-AX, which host-AX / simdrive CANNOT inspect on the
            // simulator. Emit the marked-block count + VoiceOver state so the
            // injection is verifiable end-to-end via log capture (CI / host-AX),
            // since neither the DOM marks nor VoiceOver focus surface to the host
            // AX bridge.
            let value = try? result.get()
            let n = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
            Log.info(#file, "PP-4533 block-nav marked \(n) blocks for VoiceOver, VoiceOver=\(UIAccessibility.isVoiceOverRunning)")
        }
    }

    /// Whether the app's custom-rotor actions are enabled. Read synchronously from
    /// the persisted `AccessibilityPreferences` (same store `AccessibilityService`
    /// loads) so the gate is available inside the synchronous accessibility
    /// configuration path; defaults to the `.default` value (on) when unset.
    private static var customRotorActionsEnabled: Bool {
        guard
          let data = UserDefaults.standard.data(forKey: AccessibilityPreferences.storageKey),
          let prefs = try? JSONDecoder().decode(AccessibilityPreferences.self, from: data)
        else {
          return AccessibilityPreferences.default.customRotorActionsEnabled
        }
        return prefs.customRotorActionsEnabled
    }

    /// A VoiceOver custom rotor that walks the marked logical blocks (see
    /// `annotateBlocksForVoiceOver()`) forward / back. Each `itemSearchBlock`
    /// invocation focuses the next / previous `[data-pp-block]` in the DOM and, on
    /// a move, posts `.layoutChanged` so VoiceOver re-reads from the new focus.
    /// Returns nil at the chapter's block boundary (DAISY reading-810, PP-4533).
    private func makeBlockRotor() -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(
            name: Strings.TPPBaseReaderViewController.blockRotorTitle
        ) { [weak self] predicate in
            guard let self = self else { return nil }
            let forward = predicate.searchDirection == .next
            let result = self.evaluateBlockMove(forward: forward)
            guard result else { return nil }
            UIAccessibility.post(notification: .layoutChanged, argument: self.navigator.view)
            return UIAccessibilityCustomRotorItemResult(
                targetElement: self.navigator.view,
                targetRange: nil
            )
        }
    }

    /// Synchronously evaluate the focus-walk JS and report whether focus moved.
    /// The rotor's `itemSearchBlock` is synchronous, so this blocks briefly on the
    /// WKWebView evaluation; the JS itself is a cheap DOM walk.
    private func evaluateBlockMove(forward: Bool) -> Bool {
        let js = TPPReaderBlockNavigation.nextBlockJavaScript(forward: forward)
        let semaphore = DispatchSemaphore(value: 0)
        var moved = false
        var movedTag = ""
        Task { @MainActor in
            let result = await self.epubNavigator.evaluateJavaScript(js)
            let value = try? result.get()
            // Non-null tag name string means it focused a block.
            if let tag = value as? String, !tag.isEmpty {
                moved = true
                movedTag = tag
            }
            semaphore.signal()
        }
        // Bounded wait so a stalled web view never hangs the AX thread.
        _ = semaphore.wait(timeout: .now() + 1.0)
        // PP-4533 observability: the focus-walk happens inside the WKWebView,
        // which host-AX/simdrive can't inspect — so log each step's outcome so
        // the step execution is verifiable via log capture (the marking-log
        // pattern). Fires per rotor step.
        Log.info(#file, "PP-4533 block-nav step forward=\(forward) moved=\(moved) tag=\(movedTag)")
        return moved
    }
    override func voiceOverStatusDidChange() {
        super.voiceOverStatusDidChange()
        configureAccessibilityActions()
    }

    override func updateViewsForVoiceOver(isRunning: Bool) {
        super.updateViewsForVoiceOver(isRunning: isRunning)
        if !isRunning {
            configureAccessibilityActions()
        }
        // Readium handles the heavy lifting: forces scroll mode,
        // sets .causesPageTurn, and implements accessibilityScroll
        // for automatic chapter advancement.
    }

    /// Reclaim first responder after each page load so UIKeyCommands stay active.
    /// WKWebView often reclaims first responder when it finishes rendering content.
    override func didChangeLocation(_ locator: Locator) {
        claimFirstResponder()

        let newHREF = locator.href.string
        let isChapterChange = (newHREF != lastChapterHREF)
        let wasManual = manualNavigationPending
        manualNavigationPending = false
        lastChapterHREF = newHREF

        guard UIAccessibility.isVoiceOverRunning, isChapterChange else { return }

        // Readium's accessibilityScroll navigates but never posts
        // .pageScrolled (WWDC 2019 Session 248). Post it immediately
        // so VoiceOver's "Read All" continues into the new chapter.
        let status = locator.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Page changed"
        UIAccessibility.post(notification: .pageScrolled, argument: status)

        // Label inline footnotes (doc-noteref/doc-footnote/doc-backlink) for
        // VoiceOver on every chapter render — manual turns AND Read-All — so a
        // non-visual reader hits semantic note references throughout (PP-4531).
        annotateFootnotesForVoiceOver()
        // Mark logical content blocks for VoiceOver on every chapter render —
        // manual turns AND Read-All — so the "Blocks" rotor can step through the
        // whole chapter (DAISY reading-810, PP-4533).
        annotateBlocksForVoiceOver()

        // For manual page turns only (toolbar buttons, keyboard, edge taps),
        // use JavaScript to focus the first content element so VoiceOver
        // lands on chapter content rather than the back button (WCAG 3.2.3).
        // Skipped for accessibilityScroll ("Read All") to avoid interrupting
        // continuous reading.
        guard wasManual else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard self.lastChapterHREF == newHREF else { return }

            // Temporarily hide the navbar from VoiceOver so it can't
            // steal focus from the content element we're about to target.
            // The navbar is always visible when VoiceOver is on, so without
            // this VoiceOver prefers the back button over web content.
            let navbar = self.navigationController?.navigationBar
            navbar?.accessibilityElementsHidden = true

            let js = """
            (function() {
                var el = document.querySelector('h1, h2, h3, h4, h5, h6, p, [role="heading"]');
                if (el) {
                    el.setAttribute('tabindex', '-1');
                    el.focus();
                    return el.tagName;
                }
                return null;
            })()
            """
            await self.epubNavigator.evaluateJavaScript(js)

            UIAccessibility.post(notification: .screenChanged, argument: self.navigator.view)

            // Restore navbar accessibility after VoiceOver has settled
            try? await Task.sleep(nanoseconds: 500_000_000)
            navbar?.accessibilityElementsHidden = false
        }
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
    /// Skips when a modal (e.g. search) is presented so we don't steal focus
    /// from its text fields (PP-3715).
    private func claimFirstResponder() {
        guard presentedViewController == nil else { return }
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    /// Refuse to give up first responder. WKWebView aggressively reclaims it
    /// after content loads, stealing it from our VC. When WKWebView is first
    /// responder, the iPadOS/iOS focus engine consumes arrow keys before
    /// UIKeyCommand matching. By staying first responder, our UIKeyCommands
    /// with wantsPriorityOverSystemBehavior fire BEFORE the focus engine.
    ///
    /// Exception: allow resignation when a modal (e.g. EPUB search) is presented,
    /// otherwise SwiftUI TextFields in the modal can never become first responder
    /// and the keyboard won't appear (PP-3715).
    @discardableResult
    override func resignFirstResponder() -> Bool {
        if presentedViewController != nil {
            return super.resignFirstResponder()
        }
        return false
    }

    /// Reclaim first responder after any modal (search, settings, TOC popover)
    /// is dismissed. With `.overFullScreen`, `viewDidAppear` is not called
    /// after dismissal, so without this, WKWebView grabs first responder and
    /// keyboard shortcuts stop working.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [weak self] in
            completion?()
            self?.claimFirstResponder()
        }
    }

    /// Block FKA from moving focus between Readium's internal WKWebViews.
    /// Allows focus updates when a modal is presented so FKA users can
    /// Tab-navigate within search or other presented views.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if presentedViewController != nil {
            return super.shouldUpdateFocus(in: context)
        }
        return false
    }

    // MARK: - UIKeyCommand (Primary Keyboard Path)

    /// UIKeyCommand with `wantsPriorityOverSystemBehavior` intercepts arrow keys
    /// BEFORE the focus engine consumes them. This is the only reliable path on
    /// iPadOS where the focus system eats arrow/space events.
    ///
    /// Exposed at internal access (default) so PP-4289 regression tests can
    /// assert that the iPad-on-Mac escape-hatch bindings (Cmd+W, Cmd+,) are
    /// present without instantiating an EPUBNavigatorViewController.
    static let readerKeyCommands: [UIKeyCommand] = {
        // Cmd+W: PP-4289 — single-scene iPad-on-Mac apps treat default Cmd+W as
        // close-window, which terminates Palace entirely from inside Reader2.
        // Bind it explicitly to closeEPUB so it dismisses the reader instead.
        let closeReader = UIKeyCommand(input: "w", modifierFlags: .command, action: #selector(keyCommandCloseReader))
        closeReader.discoverabilityTitle = Strings.Generic.goBack
        // Cmd+,: PP-4289 — discoverable shortcut for reader preferences.
        let openSettings = UIKeyCommand(input: ",", modifierFlags: .command, action: #selector(keyCommandShowSettings))
        openSettings.discoverabilityTitle = Strings.TPPEPUBViewController.readerSettings

        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyCommandGoBackward)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyCommandGoForward)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyCommandGoForward)),
            UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(keyCommandGoBackward)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(keyCommandToggleUI)),
            UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(keyCommandGoBackward)),
            UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(keyCommandGoForward)),
            closeReader,
            openSettings
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

    @objc private func keyCommandCloseReader() {
        closeEPUB()
    }

    @objc private func keyCommandShowSettings() {
        guard presentedViewController == nil else { return }
        presentUserSettings()
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

        navigationHub.coordinator?.pop()
    }

    override func viewSafeAreaInsetsDidChange() {
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopKeyboardInputMonitoring()
        resetNavigationAppearance()
    }

    private func resetNavigationAppearance() {
        let appearance = TPPConfiguration.defaultAppearance()
        navigationController?.navigationBar.isTranslucent = false
        navigationController?.navigationBar.setAppearance(appearance)
        navigationController?.navigationBar.forceUpdateAppearance(style: systemUserInterfaceStyle)
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

        // Advanced Typography (feature-flagged)
        if ReaderTypographyButton.isEnabled {
            let typoButton = ReaderTypographyButtonUIKit()
            typoButton.onTap = { [weak self] in
                guard let self = self else { return }
                let sheet = ReaderTypographyButtonUIKit.makeTypographySheet()
                self.present(sheet, animated: true)
            }
            buttons.append(UIBarButtonItem(customView: typoButton))
        }

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
