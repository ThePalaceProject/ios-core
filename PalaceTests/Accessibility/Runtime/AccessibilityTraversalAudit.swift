//
//  AccessibilityTraversalAudit.swift
//  PalaceTests
//
//  Walks a live view hierarchy's accessibility tree the way VoiceOver does and
//  activates every actionable element the way a double-tap does: first
//  `accessibilityActivate()`, then a hit-test at the activation point that must
//  land in the element's own control. Runs in-process so screens use fixtures
//  and spies. Not modelled: swipe order, rotors, focus, WKWebView page content.
//

import UIKit
import XCTest

/// One element VoiceOver can land on.
struct AXAuditElement {
    let object: NSObject
    /// Label with surrounding whitespace trimmed; empty when there is none.
    let label: String
    let traits: UIAccessibilityTraits
    /// Screen-coordinate frame, as VoiceOver draws its cursor.
    let frame: CGRect
    /// Type path from the audited root, for failure messages.
    let path: String

    /// Elements a VoiceOver user can act on with a double-tap (or, for
    /// `.adjustable`, with swipe up/down).
    var isActionable: Bool {
        if traits.contains(.notEnabled) { return false }
        if traits.contains(.button) || traits.contains(.link) || traits.contains(.adjustable) {
            return true
        }
        if let control = object as? UIControl { return control.isEnabled }
        return false
    }

    var isAdjustable: Bool { traits.contains(.adjustable) }

    /// Short name for reports: the label, or the type path when unlabeled.
    var displayName: String { label.isEmpty ? "<unlabeled \(path)>" : "\"\(label)\"" }
}

/// Outcome of activating one element.
enum AXActivationResult: Equatable {
    case activated(via: String)
    case failed(reason: String)

    var succeeded: Bool {
        if case .activated = self { return true }
        return false
    }
}

/// A single defect, formatted for a test failure message.
struct AXAuditViolation: CustomStringConvertible, Equatable {
    enum Kind: Equatable {
        case missingLabel
        case zeroSizeFrame
        case activationFailed(String)
        case adjustableDoesNotAdjust
        case touchTargetTooSmall(CGSize)
        case labelContainsHint(String)
    }

    let screen: String
    let element: String
    let kind: Kind

    var description: String {
        switch kind {
        case .missingLabel:
            return "[\(screen)] \(element): actionable element has no accessibility label"
        case .zeroSizeFrame:
            return "[\(screen)] \(element): actionable element has a zero-size frame, VoiceOver cannot focus it"
        case .activationFailed(let reason):
            return "[\(screen)] \(element): double-tap does not activate (\(reason))"
        case .adjustableDoesNotAdjust:
            return "[\(screen)] \(element): adjustable element's value does not change on increment or decrement"
        case .touchTargetTooSmall(let size):
            return "[\(screen)] \(element): touch target is \(Int(size.width))x\(Int(size.height)) pt, under the 44x44 pt minimum"
        case .labelContainsHint(let phrase):
            return "[\(screen)] \(element): label contains the hint text \"\(phrase)\"; VoiceOver reads hints from accessibilityHint"
        }
    }
}

struct AXAuditReport {
    let screen: String
    let elements: [AXAuditElement]
    let activations: [(element: AXAuditElement, result: AXActivationResult)]
    let violations: [AXAuditViolation]

    var actionable: [AXAuditElement] { elements.filter(\.isActionable) }
    var labels: [String] { elements.map(\.label) }

    /// First element whose label equals `label` exactly.
    func element(labeled label: String) -> AXAuditElement? {
        elements.first { $0.label == label }
    }

    /// Human-readable dump, attached to failures so a red run shows the tree.
    var dump: String {
        elements.map { el in
            let marker = el.isActionable ? "*" : " "
            return "\(marker) \(el.displayName) traits=\(el.traits.rawValue) frame=\(el.frame.integral) \(el.path)"
        }.joined(separator: "\n")
    }
}

@MainActor
enum AccessibilityTraversalAudit {

    // MARK: - Traversal

    static func traverse(_ root: UIView) -> [AXAuditElement] {
        var out: [AXAuditElement] = []
        visit(root, path: typeName(root), depth: 0, into: &out)
        return out
    }

    private static let maxDepth = 80

    private static func visit(_ object: NSObject, path: String, depth: Int, into out: inout [AXAuditElement]) {
        guard depth < maxDepth else { return }
        if object.accessibilityElementsHidden { return }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }

        if object.isAccessibilityElement {
            out.append(AXAuditElement(
                object: object,
                label: (object.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                traits: object.accessibilityTraits,
                frame: screenFrame(of: object),
                path: path
            ))
            return
        }

        for child in children(of: object) {
            visit(child, path: path + " > " + typeName(child), depth: depth + 1, into: &out)
        }
    }

    /// `accessibilityFrame`, falling back to the view's own frame in screen
    /// coordinates when it is unset — UIKit documents the view's frame as the
    /// default, but a plain `UIView` subclass reports `.zero` in-process.
    private static func screenFrame(of object: NSObject) -> CGRect {
        let frame = object.accessibilityFrame
        guard frame == .zero, let view = object as? UIView, let window = view.window else { return frame }
        return window.convert(view.convert(view.bounds, to: window), to: window.screen.coordinateSpace)
    }

    private static func children(of object: NSObject) -> [NSObject] {
        if let elements = object.accessibilityElements, !elements.isEmpty {
            return restrictToModal(elements.compactMap { $0 as? NSObject })
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return restrictToModal((0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject })
        }
        if let view = object as? UIView {
            return restrictToModal(view.subviews)
        }
        return []
    }

    /// VoiceOver ignores the siblings of a view that declares itself modal.
    private static func restrictToModal(_ siblings: [NSObject]) -> [NSObject] {
        if let modal = siblings.last(where: { $0.accessibilityViewIsModal && !(($0 as? UIView)?.isHidden ?? false) }) {
            return [modal]
        }
        return siblings
    }

    private static func typeName(_ object: NSObject) -> String {
        let name = String(describing: type(of: object))
        // SwiftUI hosting-view generics are thousands of characters long.
        if let generic = name.firstIndex(of: "<") { return String(name[..<generic]) }
        return name
    }

    // MARK: - Activation

    /// Activates `element` the way a VoiceOver double-tap does. This fires the
    /// element's real action, so callers mount screens against spy services.
    static func activate(_ element: AXAuditElement, in window: UIWindow) -> AXActivationResult {
        if element.object.accessibilityActivate() {
            return .activated(via: "accessibilityActivate")
        }

        // The documented default activation point is the frame's midpoint;
        // like the frame, it reads `.zero` in-process for a plain view.
        var screenPoint = element.object.accessibilityActivationPoint
        if screenPoint == .zero, element.object is UIView {
            screenPoint = CGPoint(x: element.frame.midX, y: element.frame.midY)
        }
        let point = window.convert(screenPoint, from: window.screen.coordinateSpace)
        guard window.bounds.contains(point) else {
            return .failed(reason: "activation point \(screenPoint) is outside the window")
        }
        guard let hit = window.hitTest(point, with: nil) else {
            return .failed(reason: "nothing is hit-testable at the activation point \(screenPoint)")
        }
        guard let control = nearestControl(from: hit) else {
            return .failed(reason: "activation point lands on \(typeName(hit)), which is not a control")
        }
        guard owns(element: element, control: control) else {
            let other = (control.accessibilityLabel ?? "").isEmpty ? typeName(control) : "\"\(control.accessibilityLabel ?? "")\""
            return .failed(reason: "activation point lands on a different control, \(other)")
        }
        guard control.isEnabled else {
            return .failed(reason: "the control at the activation point is disabled")
        }
        control.sendActions(for: .touchUpInside)
        return .activated(via: "tap at activation point → \(typeName(control))")
    }

    private static func nearestControl(from view: UIView) -> UIControl? {
        var current: UIView? = view
        while let v = current {
            if let control = v as? UIControl { return control }
            current = v.superview
        }
        return nil
    }

    /// The control belongs to the element when one view contains the other, or
    /// when the control sits entirely inside the element's frame. The second
    /// case covers SwiftUI nodes that wrap a UIKit control (AirPlay's
    /// `AVRoutePickerView`) and non-view `UIAccessibilityElement`s. A control
    /// that merely overlaps the element, such as a full-screen overlay, fails.
    private static func owns(element: AXAuditElement, control: UIControl) -> Bool {
        if let view = element.object as? UIView,
           control === view || control.isDescendant(of: view) || view.isDescendant(of: control) {
            return true
        }
        let controlFrame = control.convert(control.bounds, to: nil)
        let screenFrame = control.window.map { $0.convert(controlFrame, to: $0.screen.coordinateSpace) } ?? controlFrame
        return element.frame.insetBy(dx: -1, dy: -1).contains(screenFrame)
    }

    /// For `.adjustable` elements VoiceOver has no double-tap action; the user
    /// swipes up or down. The element passes when either direction changes its
    /// accessibility value.
    static func adjust(_ element: AXAuditElement) -> Bool {
        let before = element.object.accessibilityValue
        element.object.accessibilityIncrement()
        if element.object.accessibilityValue != before { return true }
        element.object.accessibilityDecrement()
        return element.object.accessibilityValue != before
    }

    // MARK: - Audit

    /// How long the audit waits for the screen to return to an element after
    /// the previous activation's reset.
    static let settleTimeout: TimeInterval = 2

    /// The live element with `element`'s label and tree position, waiting up to
    /// `settleTimeout` while the run loop lets dismissals finish.
    private static func waitForElement(matching element: AXAuditElement, in root: UIView) -> AXAuditElement? {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while true {
            if let live = traverse(root).first(where: { $0.label == element.label && $0.path == element.path }) {
                return live
            }
            if Date() >= deadline { return nil }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Apple's minimum touch target (Human Interface Guidelines, "Accessibility").
    static let minimumTouchTarget = CGSize(width: 44, height: 44)

    /// Instructions VoiceOver already speaks from the hint or the trait; in a
    /// label they are read twice, and they cannot be turned off in settings.
    nonisolated static let hintPhrases = ["double-tap", "double tap", "tap to "]

    /// The first hint phrase `label` contains, compared case-insensitively.
    nonisolated static func hintPhrase(in label: String) -> String? {
        let lowered = label.lowercased()
        return hintPhrases.first { lowered.contains($0) }
    }

    /// Traverses `root`, then checks every actionable element for a label, a
    /// focusable frame, and a working activation.
    ///
    /// - Parameters:
    ///   - checkTouchTargets: also report actionable elements whose frame is
    ///     under `minimumTouchTarget` in either dimension.
    ///   - activate: whether to fire actions. Elements for which it returns
    ///     `false` are still checked for label and frame.
    ///   - afterEachActivation: runs after every activation, so the caller can
    ///     dismiss anything it presented before the next element fires.
    static func audit(
        screen: String,
        root: UIView,
        window: UIWindow,
        checkTouchTargets: Bool = false,
        activate shouldActivate: (AXAuditElement) -> Bool = { _ in true },
        afterEachActivation: (AXAuditElement) -> Void = { _ in }
    ) -> AXAuditReport {
        let elements = traverse(root)
        var violations: [AXAuditViolation] = []
        var activations: [(AXAuditElement, AXActivationResult)] = []

        for element in elements where element.isActionable {
            if element.label.isEmpty {
                violations.append(.init(screen: screen, element: element.displayName, kind: .missingLabel))
            }
            if let phrase = hintPhrase(in: element.label) {
                violations.append(.init(screen: screen, element: element.displayName, kind: .labelContainsHint(phrase)))
            }
            if element.frame.width < 1 || element.frame.height < 1 {
                violations.append(.init(screen: screen, element: element.displayName, kind: .zeroSizeFrame))
            } else if checkTouchTargets,
                      element.frame.width < minimumTouchTarget.width || element.frame.height < minimumTouchTarget.height {
                violations.append(.init(screen: screen, element: element.displayName,
                                        kind: .touchTargetTooSmall(element.frame.size)))
            }
            guard shouldActivate(element) else { continue }

            // An earlier activation may have navigated away and back, which
            // rebuilds bar-button views, or opened a menu that is still
            // animating closed (a modal overlay hides its siblings until it
            // leaves; on iOS 18 that outlasts a fixed settle). Activate the
            // element as it exists once it is back, matched by label and
            // position in the tree.
            guard let element = waitForElement(matching: element, in: root) else {
                let now = traverse(root).map { "  \($0.displayName) \($0.path)" }.joined(separator: "\n")
                violations.append(.init(screen: screen, element: element.displayName,
                                        kind: .activationFailed("no longer in the accessibility tree \(settleTimeout)s after the previous control was activated and the screen reset; tree now:\n\(now)")))
                continue
            }

            if element.isAdjustable {
                if !adjust(element) {
                    violations.append(.init(screen: screen, element: element.displayName, kind: .adjustableDoesNotAdjust))
                }
                continue
            }
            let result = activate(element, in: window)
            activations.append((element, result))
            if case .failed(let reason) = result {
                violations.append(.init(screen: screen, element: element.displayName, kind: .activationFailed(reason)))
            }
            afterEachActivation(element)
        }

        return AXAuditReport(screen: screen, elements: elements, activations: activations, violations: violations)
    }
}

// MARK: - Accessibility runtime

/// UIKit and SwiftUI build accessibility elements only while the process's
/// accessibility runtime is active. On a simulator where nothing has turned it
/// on (a fresh CI simulator), every hosted view reports an empty tree, so an
/// audit would see nothing. This turns on the same automation mode XCUITest
/// and KIF use, through `libAccessibility`'s `_AXSSetAutomationEnabled`.
///
/// The setting is simulator-wide and outlives the process, so `restore()`
/// puts back the value found at `enable()`. A marker file records that this
/// code turned the flag on, so a run that died before restoring is cleaned
/// up by the next one instead of leaving the flag on for good.
@MainActor
enum AccessibilityRuntime {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    private static var original: Int32?

    private static let symbols: (get: Getter, set: Setter)? = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let get = dlsym(handle, "_AXSAutomationEnabled"),
              let set = dlsym(handle, "_AXSSetAutomationEnabled") else { return nil }
        return (unsafeBitCast(get, to: Getter.self), unsafeBitCast(set, to: Setter.self))
    }()

    /// Where the marker lives: simulator-wide, like the flag itself, so a
    /// run in a reinstalled app still finds a marker an earlier run left.
    static var markerDirectory: URL = {
        if let shared = ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] {
            return URL(fileURLWithPath: shared)
        }
        return FileManager.default.temporaryDirectory
    }()

    /// Present while a run has turned the flag on and not yet restored it.
    static var markerURL: URL {
        markerDirectory.appendingPathComponent("palace-a11y-audit-turned-on-automation")
    }

    /// The value `restore()` puts back. A marker means an earlier run turned
    /// the flag on and ended (crashed or was killed) before restoring it, so
    /// the flag's current "on" is that run's leftover and "off" is restored.
    nonisolated static func valueToRestore(current: Int32, markerFromUnfinishedRun: Bool) -> Int32 {
        markerFromUnfinishedRun ? 0 : current
    }

    static var isEnabled: Bool { (symbols?.get() ?? 0) != 0 }

    /// Returns `false` when the runtime cannot be reached; callers fail then,
    /// because every assertion after it would be vacuous.
    @discardableResult
    static func enable() -> Bool {
        guard let symbols else { return false }
        if original == nil {
            original = valueToRestore(
                current: symbols.get(),
                markerFromUnfinishedRun: FileManager.default.fileExists(atPath: markerURL.path)
            )
        }
        if symbols.get() == 0 { symbols.set(1) }
        if original == 0 {
            FileManager.default.createFile(atPath: markerURL.path, contents: nil)
        }
        return symbols.get() != 0
    }

    static func restore() {
        guard let symbols, let original else { return }
        symbols.set(original)
        try? FileManager.default.removeItem(at: markerURL)
        self.original = nil
    }
}

// MARK: - Hosting

/// Mounts a view controller in a real key window, sized like an iPhone 16 Pro,
/// and tears it down afterwards.
@MainActor
final class AccessibilityAuditHost {
    let window: UIWindow

    init(_ root: UIViewController, size: CGSize = CGSize(width: 402, height: 874)) {
        let runtimeActive = AccessibilityRuntime.enable()
        XCTAssertTrue(runtimeActive, "could not enable the accessibility runtime; the audit would read an empty tree")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.rootViewController = root
        // Visible but NOT key: the app presents first-launch UI (library
        // picker, alerts) on the key window, which would cover the screen
        // under audit.
        window.isHidden = false
        settle()
    }

    /// Lets layout, SwiftUI updates and `onAppear` work run.
    func settle(_ seconds: TimeInterval = 0.4) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
