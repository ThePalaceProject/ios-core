//
//  StreamingReaderViewController.swift
//  Palace
//
//  PP-4161: UIKit shell hosting a WKWebView for streaming-media (text/html)
//  OPDS titles. No JS bridge, no annotation layer, no TOC/font/theme/print
//  /share — Close + scroll only per the intent file anti-claims.
//

import Combine
import UIKit
import WebKit

/// Narrow seam over `WKWebView.evaluateJavaScript(_:completionHandler:)` so
/// the scroll-restore retry loop can be exercised deterministically in tests
/// without a real WKWebView. Production binds to `WKWebView` via the
/// extension below; tests inject a recording stub.
protocol ScriptEvaluating: AnyObject {
    func evaluate(
        _ javaScript: String,
        completion: ((Any?, Error?) -> Void)?
    )
}

extension WKWebView: ScriptEvaluating {
    func evaluate(
        _ javaScript: String,
        completion: ((Any?, Error?) -> Void)?
    ) {
        evaluateJavaScript(javaScript, completionHandler: completion)
    }
}

/// UIKit shell for the streaming reader. The SwiftUI surface area uses
/// `StreamingReaderView` which wraps this VC via `UIViewControllerRepresentable`.
public final class StreamingReaderViewController: UIViewController {

    private let viewModel: StreamingReaderViewModel

    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.accessibilityIdentifier = AccessibilityID.StreamingReader.webView
        return wv
    }()

    private lazy var errorContainer: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        container.accessibilityIdentifier = AccessibilityID.StreamingReader.errorContainer
        container.backgroundColor = .systemBackground

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = Strings.StreamingReader.connectionRequired
        container.addSubview(label)

        let retryButton = UIButton(type: .system)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle(Strings.StreamingReader.retry, for: .normal)
        retryButton.accessibilityIdentifier = AccessibilityID.StreamingReader.retryButton
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        container.addSubview(retryButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -20),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            retryButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            retryButton.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])

        return container
    }()

    private var pendingRestoredScroll: CGFloat?
    private var cancellables = Set<AnyCancellable>()
    private var dismissalSaved = false

    // MARK: - Scroll-restore tuning (overridable for tests)

    /// Pixel tolerance for "page has settled on the target offset." The
    /// BiblioBoard fulfill page reflows several times after `didFinish`
    /// (async image loads, JS-driven layout); a strict equality check
    /// would loop unnecessarily on sub-pixel drift.
    var scrollRestoreToleranceY: CGFloat = 8.0

    /// Max retry attempts before we give up and let the user scroll
    /// manually. Default 8 × 250ms ≈ 2s of soak time, which empirically
    /// covers the BiblioBoard reflow window without locking the UI.
    var scrollRestoreMaxAttempts: Int = 8

    /// Backoff between JS `window.scrollTo` retries. Held as nanoseconds
    /// for the `Task.sleep(nanoseconds:)` API. Tests override to 0 so
    /// the loop runs without wall-clock delay.
    var scrollRestoreRetryDelayNanos: UInt64 = 250_000_000

    /// JS-evaluation seam. Defaults to the production WKWebView; tests
    /// inject a recording stub via `setScriptEvaluator(_:)`. We hold an
    /// unowned-style reference (set in viewDidLoad) so the test stub can
    /// observe `restoreScroll(to:attempt:)` calls without a real WKWebView.
    private var scriptEvaluator: ScriptEvaluating?

    /// Test-only seam. Production never calls this — it's used by
    /// `StreamingReaderViewControllerScrollRestoreTests` to inject a
    /// recording `ScriptEvaluating` stub before `viewDidLoad` wires up
    /// the real WKWebView.
    func setScriptEvaluator(_ evaluator: ScriptEvaluating) {
        scriptEvaluator = evaluator
    }

    /// Test-only seam. Production sets `pendingRestoredScroll` via the
    /// VM's `.ready(_, restoredScroll:)` state-change subscription in
    /// `render(_:)`. Tests skip the Combine hop and seed directly so
    /// the `handleDidFinish` branch can be exercised synchronously.
    func setPendingRestoredScroll(_ y: CGFloat?) {
        pendingRestoredScroll = y
    }

    // MARK: - Init

    public init(viewModel: StreamingReaderViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("StreamingReaderViewController does not support NSCoding")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installSubviews()
        bindViewModel()
        webView.navigationDelegate = self
        webView.scrollView.delegate = self
        if scriptEvaluator == nil {
            scriptEvaluator = webView
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Guard against double-fire (e.g. dismissal + parent-pop). The VM's
        // didDismiss is safe to call twice but we want one save per session.
        guard !dismissalSaved else { return }
        dismissalSaved = true
        viewModel.didDismiss()
    }

    // MARK: - Setup

    private func installSubviews() {
        view.addSubview(webView)
        view.addSubview(errorContainer)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorContainer.topAnchor.constraint(equalTo: view.topAnchor),
            errorContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func bindViewModel() {
        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.render(state)
            }
            .store(in: &cancellables)
    }

    private func render(_ state: StreamingReaderState) {
        switch state {
        case .loading:
            errorContainer.isHidden = true
            webView.isHidden = false
        case let .ready(url, restoredScroll):
            errorContainer.isHidden = true
            webView.isHidden = false
            pendingRestoredScroll = restoredScroll
            webView.load(URLRequest(url: url))
        case .offline:
            errorContainer.isHidden = false
            webView.isHidden = true
        case .failed:
            errorContainer.isHidden = false
            webView.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func retryTapped() {
        viewModel.reload()
    }
}

// MARK: - WKNavigationDelegate

extension StreamingReaderViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        handleDidFinish(currentScrollY: webView.scrollView.contentOffset.y)
    }

    /// Internal seam so tests can drive the didFinish branch without
    /// constructing a `WKNavigation` (no public initializer) or driving
    /// a real WKWebView load. Production calls this from the
    /// WKNavigationDelegate method above; tests call it after seeding
    /// `pendingRestoredScroll` via a `.ready(_, restoredScroll:)` VM
    /// state.
    ///
    /// Apply restored scroll offset via JS so we ride the page's own
    /// layout loop. `UIScrollView.setContentOffset` at didFinish races
    /// post-load JS reflows on pages like BiblioBoard's fulfill URL:
    /// the scrollView offset gets clobbered by the next layout pass.
    /// `window.scrollTo()` + `window.scrollY` verification + retry gives
    /// the page time to settle and confirms we landed.
    func handleDidFinish(currentScrollY: CGFloat) {
        viewModel.didNavigationFinish(scrollOffset: currentScrollY)
        guard let restored = pendingRestoredScroll, restored > 0 else {
            pendingRestoredScroll = nil
            return
        }
        pendingRestoredScroll = nil
        restoreScroll(to: restored, attempt: 0)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        render(.failed(error))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        render(.failed(error))
    }

    /// Drives `window.scrollTo(0, targetY)` then reads back `window.scrollY`
    /// to verify the page actually landed there. Pages whose layout is
    /// still settling (BiblioBoard's PINPOINT MY LOCATION reflow being the
    /// canonical PP-4161 case) will return a smaller `actual` than
    /// requested; we retry with backoff up to `scrollRestoreMaxAttempts`.
    ///
    /// Internal-not-private so the test target can drive it directly via
    /// `@testable import` (the stub `ScriptEvaluating` records the JS
    /// strings and we replay synthetic completion-handler results to
    /// exercise the retry branch).
    func restoreScroll(to targetY: CGFloat, attempt: Int) {
        guard attempt < scrollRestoreMaxAttempts else { return }
        guard let evaluator = scriptEvaluator else { return }
        let target = Int(targetY)
        let js = """
            (function() {
                window.scrollTo(0, \(target));
                return { actual: window.scrollY, ready: document.readyState };
            })();
            """
        evaluator.evaluate(js) { [weak self] result, _ in
            guard let self = self else { return }
            let actualY = Self.parseActualY(from: result)
            // Couldn't read the actual offset (eval failed, or the page
            // refused the script). Retry once more so a transient
            // failure doesn't strand the user at y=0, then bail.
            guard let actual = actualY else {
                self.scheduleScrollRestoreRetry(to: targetY, nextAttempt: attempt + 1)
                return
            }
            if abs(actual - targetY) < self.scrollRestoreToleranceY {
                return  // close enough — page settled at the saved offset
            }
            self.scheduleScrollRestoreRetry(to: targetY, nextAttempt: attempt + 1)
        }
    }

    private func scheduleScrollRestoreRetry(to targetY: CGFloat, nextAttempt: Int) {
        let delay = scrollRestoreRetryDelayNanos
        Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            self?.restoreScroll(to: targetY, attempt: nextAttempt)
        }
    }

    /// Extracts the `actual` key from the JS dictionary result, accepting
    /// either `NSNumber` (the WKWebView round-trip type) or `Double` /
    /// `Int` (test stubs). Returns nil on any shape mismatch so the
    /// caller can retry rather than crash.
    static func parseActualY(from result: Any?) -> CGFloat? {
        guard let dict = result as? [String: Any] else { return nil }
        if let n = dict["actual"] as? NSNumber {
            return CGFloat(n.doubleValue)
        }
        if let d = dict["actual"] as? Double {
            return CGFloat(d)
        }
        if let i = dict["actual"] as? Int {
            return CGFloat(i)
        }
        return nil
    }
}

// MARK: - UIScrollViewDelegate

extension StreamingReaderViewController: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        viewModel.didNavigationFinish(scrollOffset: scrollView.contentOffset.y)
    }
}
