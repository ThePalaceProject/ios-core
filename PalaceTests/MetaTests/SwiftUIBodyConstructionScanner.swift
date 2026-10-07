//
//  SwiftUIBodyConstructionScanner.swift
//  PalaceTests
//
//  Finds view controllers and web views constructed while a SwiftUI view's
//  content is built. Used by `HeavyObjectInSwiftUIBodyLintTests` (#1620).
//

import Foundation

/// A source scanner, not a parser. It removes comments and string literals,
/// finds the scopes that run each time a view's content is built, and reports
/// direct initialiser calls of heavyweight types inside them.
///
/// Scopes: the braces of `var <name>: some View` / `AnyView` (including `body`)
/// and of `func ... -> some View` / `AnyView`, matched brace by brace.
///
/// Inside a scope these are deferred and not reported:
/// - an argument of a call whose parameter is `@autoclosure` (`autoclosureCallees`);
/// - a closure passed with an action label (`action:`, `perform:`, ...);
/// - the trailing closure of an event modifier (`onAppear`, `task`, ...), of
///   `Task`, and of a `Button` that has no `action:` argument.
///
/// Known limits:
/// - only direct initialisers are seen; a helper method or factory that builds
///   a controller (`coordinator.makeController()`) is not followed;
/// - a closure stored in a local (`let make = { Controller() }`) is reported,
///   although it may never run;
/// - content closures (`.sheet { }`, `NavigationLink { }`) count as view content;
/// - a `func` whose parameter list contains `{` (a default closure) is not
///   recognised as a scope;
/// - types are matched by name only, so a local type that shadows a heavy name
///   is reported.
enum SwiftUIBodyConstructionScanner {

    struct Finding: Equatable, CustomStringConvertible {
        let path: String
        let line: Int
        let typeName: String
        let scope: String

        var description: String { "\(path):\(line): \(typeName)( in `\(scope)`" }
    }

    /// Always heavy, whatever the class census finds.
    static let seedHeavyTypes: Set<String> = [
        "WKWebView", "RemoteHTMLViewController", "BundledHTMLViewController",
    ]

    /// SDK roots of the class census. These and every subclass declared in the
    /// scanned sources are heavy.
    static let sdkRootTypes: Set<String> = [
        "UIViewController", "UINavigationController", "UITableViewController",
        "UICollectionViewController", "UIPageViewController", "UITabBarController",
        "UISplitViewController", "UIHostingController", "UIAlertController",
        "UIActivityViewController", "UIDocumentPickerViewController",
        "UIImagePickerController", "SFSafariViewController", "AVPlayerViewController",
        "MFMailComposeViewController", "QLPreviewController", "WKWebView",
    ]

    /// Calls whose first argument is `@autoclosure`, so a controller written
    /// there is built later. `testAutoclosureCalleesReallyTakeAutoclosures`
    /// keeps this list honest.
    static let autoclosureCallees: Set<String> = ["UIViewControllerWrapper"]

    /// Argument labels whose closure runs on an event, not during rendering.
    static let deferredLabels: Set<String> = [
        "action", "perform", "onDismiss", "onCommit", "onEditingChanged",
        "onCompletion", "completion", "completionHandler", "handler",
    ]

    /// Callees whose trailing closure runs on an event, not during rendering.
    static let deferredTrailingCallees: Set<String> = [
        "onAppear", "onDisappear", "task", "onChange", "onReceive", "onSubmit",
        "onTapGesture", "onLongPressGesture", "onEnded", "onChanged", "onOpenURL",
        "refreshable", "onDrop", "onDelete", "onMove", "onContinueUserActivity",
        "Task", "detached", "async", "asyncAfter",
    ]

    // MARK: - Heavy type census

    /// The seeds, the SDK roots, and every class in `sources` that inherits
    /// from one of them (Swift `class A: B` and Objective-C `@interface A : B`).
    static func heavyTypes(declaredIn sources: [String]) -> Set<String> {
        heavyTypes(declaredInCode: sources.map(stripCommentsAndStrings))
    }

    /// `heavyTypes(declaredIn:)` over sources already passed through
    /// `stripCommentsAndStrings`.
    static func heavyTypes(declaredInCode strippedSources: [String]) -> Set<String> {
        let swiftClass = try! NSRegularExpression(
            pattern: #"\bclass\s+(\w+)\s*(?:<[^>{]*>)?\s*:\s*(?:\w+\.)?(\w+)"#)
        let objcClass = try! NSRegularExpression(pattern: #"@interface\s+(\w+)\s*:\s*(\w+)"#)
        var superOf: [String: String] = [:]
        for code in strippedSources {
            let range = NSRange(code.startIndex..., in: code)
            for regex in [swiftClass, objcClass] {
                for match in regex.matches(in: code, range: range) {
                    guard let name = Range(match.range(at: 1), in: code),
                          let parent = Range(match.range(at: 2), in: code) else { continue }
                    superOf[String(code[name])] = String(code[parent])
                }
            }
        }
        var heavy = seedHeavyTypes.union(sdkRootTypes)
        var grew = true
        while grew {
            grew = false
            for (name, parent) in superOf where !heavy.contains(name) && heavy.contains(parent) {
                heavy.insert(name)
                grew = true
            }
        }
        return heavy
    }

    // MARK: - Scan

    /// Findings in one file's `source`; `path` is copied into each finding.
    static func findings(in source: String, path: String, heavyTypes: Set<String>) -> [Finding] {
        findings(inCode: stripCommentsAndStrings(source), path: path, heavyTypes: heavyTypes)
    }

    /// `findings(in:path:heavyTypes:)` over a source already passed through
    /// `stripCommentsAndStrings`.
    static func findings(inCode code: String, path: String, heavyTypes: Set<String>) -> [Finding] {
        let bytes = Array(code.utf8)
        var lineStarts = [0]
        for (i, b) in bytes.enumerated() where b == UInt8(ascii: "\n") { lineStarts.append(i + 1) }
        func line(of offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }

        var seen = Set<Int>()
        var out: [Finding] = []
        for scope in viewScopes(in: code) {
            for (offset, name) in heavyConstructions(in: bytes, from: scope.open, to: scope.close, heavyTypes: heavyTypes)
            where seen.insert(offset).inserted {
                out.append(Finding(path: path, line: line(of: offset), typeName: name, scope: scope.name))
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    // MARK: - Scopes

    struct Scope { let name: String; let open: Int; let close: Int }

    private static let scopeHeaders = [
        try! NSRegularExpression(pattern: #"\bvar\s+(\w+)\s*:\s*(?:some\s+View|AnyView)\s*\{"#),
        try! NSRegularExpression(
            pattern: #"\bfunc\s+(\w+)[^{};]*?->\s*(?:some\s+View|AnyView)\s*(?:where\s[^{]*)?\{"#),
    ]

    /// View-content scopes in comment- and string-free ASCII `code`.
    static func viewScopes(in code: String) -> [Scope] {
        let bytes = Array(code.utf8)
        let range = NSRange(location: 0, length: bytes.count)
        var scopes: [Scope] = []
        for regex in scopeHeaders {
            for match in regex.matches(in: code, range: range) {
                let open = match.range.location + match.range.length - 1
                guard let close = matchingBrace(in: bytes, open: open) else { continue }
                let name = (code as NSString).substring(with: match.range(at: 1))
                scopes.append(Scope(name: name, open: open, close: close))
            }
        }
        return scopes
    }

    private static func matchingBrace(in bytes: [UInt8], open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "{") { depth += 1 }
            if bytes[i] == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Construction sites

    private struct Frame {
        let isParen: Bool
        let callee: String
        let deferred: Bool
        var sawActionLabel = false
    }

    private static func isIdentByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// The identifier that ends at `end` (inclusive), skipping a generic
    /// argument list such as `Wrapper<Foo>`.
    private static func identifier(endingAt end: Int, in bytes: [UInt8]) -> String {
        var j = end
        if j >= 0, bytes[j] == UInt8(ascii: ">") {
            var depth = 0
            while j >= 0 {
                if bytes[j] == UInt8(ascii: ">") { depth += 1 }
                if bytes[j] == UInt8(ascii: "<") { depth -= 1; if depth == 0 { j -= 1; break } }
                j -= 1
            }
        }
        var start = j
        while start >= 0, isIdentByte(bytes[start]) { start -= 1 }
        guard start < j else { return "" }
        return String(decoding: bytes[(start + 1)...j], as: UTF8.self)
    }

    private static func previousNonSpace(before index: Int, in bytes: [UInt8]) -> Int {
        var j = index - 1
        while j >= 0, isSpace(bytes[j]) { j -= 1 }
        return j
    }

    private static func heavyConstructions(
        in bytes: [UInt8], from open: Int, to close: Int, heavyTypes: Set<String>
    ) -> [(Int, String)] {
        var stack: [Frame] = []
        var lastClosedParen: (end: Int, callee: String, sawAction: Bool)?
        var out: [(Int, String)] = []
        var i = open + 1
        while i < close {
            let b = bytes[i]
            if isIdentByte(b), i == 0 || !isIdentByte(bytes[i - 1]) {
                var end = i
                while end < close, isIdentByte(bytes[end]) { end += 1 }
                // Type names start with a capital; `action` is the one lower-case word read.
                guard (b >= 0x41 && b <= 0x5A) || b == UInt8(ascii: "a") else { i = end; continue }
                let name = String(decoding: bytes[i..<end], as: UTF8.self)
                var next = end
                while next < close, isSpace(bytes[next]) { next += 1 }
                if name == "action", next < close, bytes[next] == UInt8(ascii: ":"),
                   let top = stack.indices.last, stack[top].isParen {
                    stack[top].sawActionLabel = true
                }
                if heavyTypes.contains(name), next < close,
                   bytes[next] == UInt8(ascii: "(") || bytes[next] == UInt8(ascii: "{"),
                   bytes[max(previousNonSpace(before: i, in: bytes), 0)] != UInt8(ascii: "."),
                   !stack.contains(where: \.deferred) {
                    out.append((i, name))
                }
                i = end
                continue
            }
            switch b {
            case UInt8(ascii: "("):
                let callee = identifier(endingAt: i - 1, in: bytes)
                stack.append(Frame(isParen: true, callee: callee,
                                   deferred: autoclosureCallees.contains(callee)))
            case UInt8(ascii: ")"):
                if let frame = stack.popLast(), frame.isParen {
                    lastClosedParen = (i, frame.callee, frame.sawActionLabel)
                }
            case UInt8(ascii: "["):
                stack.append(Frame(isParen: false, callee: "", deferred: false))
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                _ = stack.popLast()
            case UInt8(ascii: "{"):
                stack.append(Frame(isParen: false, callee: "",
                                   deferred: closureIsDeferred(at: i, in: bytes, lastClosedParen: lastClosedParen)))
            default:
                break
            }
            i += 1
        }
        return out
    }

    private static func closureIsDeferred(
        at brace: Int, in bytes: [UInt8], lastClosedParen: (end: Int, callee: String, sawAction: Bool)?
    ) -> Bool {
        let p = previousNonSpace(before: brace, in: bytes)
        guard p >= 0 else { return false }
        if bytes[p] == UInt8(ascii: ":") {
            return deferredLabels.contains(identifier(endingAt: previousNonSpace(before: p, in: bytes), in: bytes))
        }
        if bytes[p] == UInt8(ascii: ")") {
            guard let closed = lastClosedParen, closed.end == p else { return false }
            if closed.callee == "Button" { return !closed.sawAction }
            return deferredTrailingCallees.contains(closed.callee)
        }
        let callee = identifier(endingAt: p, in: bytes)
        return callee == "Button" || deferredTrailingCallees.contains(callee)
    }

    // MARK: - Lexing

    /// `source` with comments and string-literal contents replaced by spaces
    /// and every non-ASCII byte replaced by a space, keeping line breaks, so
    /// byte offsets, UTF-16 offsets and line numbers agree.
    static func stripCommentsAndStrings(_ source: String) -> String {
        let src = Array(source.utf8)
        var out = src
        let n = src.count

        enum Mode {
            case code(parenDepth: Int)          // depth counts parens inside an interpolation
            case string(hashes: Int, multiline: Bool)
        }
        var modes: [Mode] = [.code(parenDepth: 0)]
        var i = 0

        func blank(_ k: Int) { if k < n, out[k] != UInt8(ascii: "\n") { out[k] = 0x20 } }
        func startsWith(_ s: String, at k: Int) -> Bool {
            var j = k
            for byte in s.utf8 {
                guard j < n, src[j] == byte else { return false }
                j += 1
            }
            return true
        }
        // Inside an interpolation everything is blanked, code included.
        var interpolationDepth: Int { modes.count - 1 }

        while i < n {
            switch modes.last! {
            case .code(let depth):
                let c = src[i]
                if interpolationDepth == 0, c != UInt8(ascii: "/"), c != UInt8(ascii: "#"), c != UInt8(ascii: "\""), c < 0x80 {
                    i += 1
                    continue
                }
                if startsWith("//", at: i) {
                    while i < n, src[i] != UInt8(ascii: "\n") { blank(i); i += 1 }
                    continue
                }
                if startsWith("/*", at: i) {
                    var nesting = 0
                    while i < n {
                        if startsWith("/*", at: i) { nesting += 1; blank(i); blank(i + 1); i += 2; continue }
                        if startsWith("*/", at: i) {
                            nesting -= 1; blank(i); blank(i + 1); i += 2
                            if nesting == 0 { break }
                            continue
                        }
                        blank(i); i += 1
                    }
                    continue
                }
                var hashes = 0
                while i + hashes < n, src[i + hashes] == UInt8(ascii: "#") { hashes += 1 }
                if i + hashes < n, src[i + hashes] == UInt8(ascii: "\"") {
                    let multiline = startsWith("\"\"\"", at: i + hashes)
                    let opener = hashes + (multiline ? 3 : 1)
                    if interpolationDepth > 0 { for k in i..<(i + opener) { blank(k) } }
                    i += opener
                    modes.append(.string(hashes: hashes, multiline: multiline))
                    continue
                }
                if interpolationDepth > 0 {
                    if src[i] == UInt8(ascii: "(") { modes[modes.count - 1] = .code(parenDepth: depth + 1) }
                    if src[i] == UInt8(ascii: ")") {
                        if depth == 0 { blank(i); modes.removeLast(); i += 1; continue }
                        modes[modes.count - 1] = .code(parenDepth: depth - 1)
                    }
                    blank(i)
                }
                if src[i] >= 0x80 { out[i] = 0x20 }
                i += 1
            case .string(let hashes, let multiline):
                if src[i] != UInt8(ascii: "\""), src[i] != UInt8(ascii: "\\"), src[i] != UInt8(ascii: "\n") {
                    blank(i)
                    i += 1
                    continue
                }
                let closer = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
                if startsWith(closer, at: i) {
                    let len = closer.utf8.count
                    if interpolationDepth > 1 { for k in i..<(i + len) { blank(k) } }
                    i += len
                    modes.removeLast()
                    continue
                }
                let escape = "\\" + String(repeating: "#", count: hashes)
                if startsWith(escape + "(", at: i) {
                    let len = escape.utf8.count + 1
                    for k in i..<(i + len) { blank(k) }
                    i += len
                    modes.append(.code(parenDepth: 0))
                    continue
                }
                if startsWith(escape, at: i) {
                    let len = escape.utf8.count + 1
                    for k in i..<min(i + len, n) { blank(k) }
                    i += len
                    continue
                }
                if !multiline, src[i] == UInt8(ascii: "\n") { modes.removeLast(); i += 1; continue }
                blank(i)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
