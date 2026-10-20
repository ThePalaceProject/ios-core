#!/usr/bin/env swift
//
//  lint-corpus-scan.swift
//
//  Runs a lint predicate over a source tree from a terminal, with no Xcode and
//  no test host. Answers two questions a reviewer asks by hand: which sites in
//  this tree match a token, and which of those have no guard on the path above
//  them.
//
//  The lexer and the brace-chain walk are the reusable halves of the census in
//  PalaceTests/MetaTests/LoanStillHeldWriterLintTests.swift (#1705). `--help`
//  carries the usage; `--self-test` runs the lexer and scope cases.
//

import Foundation

// MARK: - lexing

/// Every line with comments and string-literal contents removed, lexed as a
/// FILE rather than line by line.
///
/// The signature is the point. A per-line sanitiser cannot see a shape that
/// spans lines, so a multi-line `/* */` whose interior names a token satisfies
/// the scan, and a `"""` body full of CSS braces moves the brace arithmetic.
/// Carrying `inBlockComment` and `inMultilineString` across lines is what makes
/// those shapes reachable at all.
///
/// This is not a Swift parser and does not need to be: it answers one question,
/// which characters on this line are code.
func codeOnly(lines: [String]) -> [String] {
    var inBlockComment = false
    var inMultilineString = false
    var out: [String] = []

    for line in lines {
        var code = ""
        let chars = Array(line)
        var i = 0

        while i < chars.count {
            if inBlockComment {
                if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if inMultilineString {
                if matches(chars, at: i, "\"\"\"") {
                    inMultilineString = false
                    i += 3
                } else {
                    i += 1
                }
                continue
            }
            // A raw string's delimiter count decides where it ends, and a
            // backslash inside one escapes nothing.
            if chars[i] == "#" {
                var hashes = 0
                var j = i
                while j < chars.count, chars[j] == "#" { hashes += 1; j += 1 }
                if j < chars.count, chars[j] == "\"" {
                    i = skipRawString(chars, from: j + 1, hashes: hashes)
                    continue
                }
            }
            if matches(chars, at: i, "\"\"\"") {
                inMultilineString = true
                i += 3
                continue
            }
            if chars[i] == "\"" {
                i = skipString(chars, from: i + 1)
                continue
            }
            if chars[i] == "/", i + 1 < chars.count {
                if chars[i + 1] == "/" { break }                  // line comment
                if chars[i + 1] == "*" { inBlockComment = true; i += 2; continue }
            }
            code.append(chars[i])
            i += 1
        }
        out.append(code)
    }
    return out
}

/// Single-line convenience. Starts with clean state by construction, so a
/// cross-line shape is correctly NOT visible to it.
func codeOnly(_ line: String) -> String {
    codeOnly(lines: [line])[0]
}

func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
    let t = Array(token)
    guard index + t.count <= chars.count else { return false }
    for k in 0..<t.count where chars[index + k] != t[k] { return false }
    return true
}

/// Index just past the closing quote, or end of line for an unterminated
/// literal. A normal string does not span lines in Swift, so running off the end
/// is the correct stopping point.
func skipString(_ chars: [Character], from start: Int) -> Int {
    var i = start
    while i < chars.count {
        if chars[i] == "\\" { i += 2; continue }
        if chars[i] == "\"" { return i + 1 }
        i += 1
    }
    return chars.count
}

func skipRawString(_ chars: [Character], from start: Int, hashes: Int) -> Int {
    var i = start
    while i < chars.count {
        if chars[i] == "\"" {
            var seen = 0
            var j = i + 1
            while j < chars.count, chars[j] == "#" { seen += 1; j += 1 }
            if seen >= hashes { return j }
        }
        i += 1
    }
    return chars.count
}

// MARK: - predicates

/// A set of literal tokens and regular expressions, either of which satisfies
/// the predicate. Both are applied to already-lexed code so that the corpus
/// scan and the self-test cannot diverge.
struct Predicate {
    var tokens: [String] = []
    var patterns: [NSRegularExpression] = []

    var isEmpty: Bool { tokens.isEmpty && patterns.isEmpty }

    func matches(_ code: String) -> Bool {
        if tokens.contains(where: { code.contains($0) }) { return true }
        guard !patterns.isEmpty else { return false }
        let range = NSRange(code.startIndex..., in: code)
        return patterns.contains { $0.firstMatch(in: code, options: [], range: range) != nil }
    }

    var description: String {
        (tokens.map { "\"\($0)\"" } + patterns.map { "/\($0.pattern)/" })
            .joined(separator: " or ")
    }
}

// MARK: - scope

/// Whether a line satisfying `guardBy` sits on the path to the site at `index`.
/// Takes LEXED lines.
///
/// Walks the enclosing brace chain outward, checking only lines at or above the
/// site's own block level and only lines ABOVE it. A brace-delimited sibling
/// block's interior is skipped; the line that OPENS such a block is checked,
/// because `if outcome == .x { return }` guards everything after it at the level
/// it sits on.
///
/// Function scope was the first shape tried and it was wrong: a function holding
/// several arms let the first arm's guard cover the later ones.
///
/// KNOWN LIMIT: a line that CLOSES one block and OPENS another is brace-neutral,
/// so the walk does not register crossing between them and a guard in the first
/// arm reads as covering a site in the second. `} else {`, `} else if x {` and
/// `} catch {` all mask identically. `--self-test` pins the shape as a
/// characterization case. So the claim is narrower than "every arm is
/// independently guarded": a site in a scope with no guard at all is reported,
/// which is the case this exists for. A site reached across a brace-neutral line
/// from an already-guarded one is not.
func guardOnThePath(lexed: [String], index: Int, guardBy: Predicate) -> Bool {
    guard index > 0 else { return false }
    var depth = 0
    for i in stride(from: index - 1, through: 0, by: -1) {
        let code = lexed[i]
        let opens = code.filter { $0 == "{" }.count
        let closes = code.filter { $0 == "}" }.count
        let levelOfLine = depth + closes - opens   // the level this line guards
        if levelOfLine <= 0 && guardBy.matches(code) { return true }
        depth = max(0, levelOfLine)
    }
    return false
}

// MARK: - options

struct Options {
    var match = Predicate()
    var guardBy = Predicate()
    var roots: [String] = []
    var extensions: [String] = ["swift"]
    var excludes: [String] = []
    var raw = false
    var minFiles = 1
    var expectFiles: [String]? = nil
    var failOnMatch = false
    var json = false
    var countOnly = false
}

let usage = """
lint-corpus-scan.swift — run a lint predicate over a source tree, no Xcode needed

USAGE
  scripts/lint-corpus-scan.swift --match <token> [--root <path>] [options]
  swift scripts/lint-corpus-scan.swift --match <token> ...

WHAT IT MATCHES
  Every line is lexed as part of its FILE before any predicate runs: line and
  block comments, string literals, multiline "..." bodies and raw strings are
  stripped. Prose that names a token therefore does not match, and a brace in a
  comment or a string does not move the scope walk. Pass --raw to match the
  unlexed lines instead, which is how you see what the lexing hides.

MODES
  inventory (default)   Print every matching site. Exit 0 — a census is not a
                        verdict.
  census (--guarded-by) Print only matching sites with NO guard on the enclosing
                        brace chain above them. Exit 1 if any.
  lint (--fail-on-match) Exit 1 if anything matches at all.

OPTIONS
  --match <token>           Literal substring, matched against lexed code. Repeatable.
  --match-regex <pattern>   Regular expression alternative to --match. Repeatable.
  --guarded-by <token>      A guard token. Repeatable. Turns on census mode.
  --guarded-by-regex <pat>  Regular-expression guard. Repeatable.
  --root <path>             Tree to walk. Repeatable. Default: Palace
  --ext <extension>         File extension to read. Repeatable. Default: swift
  --exclude <substring>     Skip paths containing this. Repeatable.
  --raw                     Match the raw lines, not the lexed code.
  --min-files <n>           Exit 2 if fewer than n files were walked. Default 1.
                            A scan whose corpus is empty otherwise reports a pass.
  --expect-files <a,b>      Exit 1 unless the set of files holding matches is
                            exactly this (basenames). Pins the census against a
                            scan that silently read nothing.
  --fail-on-match           Exit 1 on any match (lint mode).
  --count                   Print counts only.
  --json                    Machine-readable output.
  --self-test               Run the lexer and scope cases, then exit.
  -h, --help                This text.

EXIT CODES
  0  ran, nothing reported
  1  findings reported (unguarded site, --expect-files mismatch, or --fail-on-match)
  2  usage error, unreadable root, or a corpus below --min-files

EXAMPLES
  # Every site that announces a finished download:
  scripts/lint-corpus-scan.swift --match 'markDownloadSuccessful(for:'

  # ...and only the ones that never ask whether the loan is still held:
  scripts/lint-corpus-scan.swift --match 'markDownloadSuccessful(for:' \\
      --guarded-by mayStoreFetchedContent --guarded-by discardedNotHeld \\
      --min-files 100 --expect-files AdobeDRMHandler.swift,LCPFulfillmentHandler.swift

  # A banned call, anywhere in the tree:
  scripts/lint-corpus-scan.swift --match-regex 'DispatchQueue\\.main\\.sync' --fail-on-match
"""

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(("lint-corpus-scan: " + message + "\n").utf8))
    exit(code)
}

func compile(_ pattern: String) -> NSRegularExpression {
    do { return try NSRegularExpression(pattern: pattern) }
    catch { die("not a usable regular expression: \(pattern)") }
}

func parse(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < argv.count else { die("\(flag) needs a value") }
        return argv[i]
    }
    while i < argv.count {
        switch argv[i] {
        case "--match":             o.match.tokens.append(value("--match"))
        case "--match-regex":       o.match.patterns.append(compile(value("--match-regex")))
        case "--guarded-by":        o.guardBy.tokens.append(value("--guarded-by"))
        case "--guarded-by-regex":  o.guardBy.patterns.append(compile(value("--guarded-by-regex")))
        case "--root":              o.roots.append(value("--root"))
        case "--ext":               o.extensions.append(value("--ext"))
        case "--exclude":           o.excludes.append(value("--exclude"))
        case "--raw":               o.raw = true
        case "--fail-on-match":     o.failOnMatch = true
        case "--count":             o.countOnly = true
        case "--json":              o.json = true
        case "--min-files":
            guard let n = Int(value("--min-files")), n >= 0 else { die("--min-files needs a non-negative integer") }
            o.minFiles = n
        case "--expect-files":
            o.expectFiles = value("--expect-files")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default:
            die("unknown option \(argv[i]). Try --help.")
        }
        i += 1
    }
    // --ext appends, so a caller-supplied list replaces the default rather than
    // widening it. Dropping the default only when something was supplied keeps
    // `--ext m` from also reading every .swift file.
    if o.extensions.count > 1 { o.extensions.removeFirst() }
    if o.roots.isEmpty { o.roots = ["Palace"] }
    return o
}

// MARK: - walking

func sourceFiles(_ o: Options) -> [String] {
    var found: [String] = []
    let fm = FileManager.default
    for root in o.roots {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory) else {
            die("no such root: \(root)")
        }
        if !isDirectory.boolValue {
            found.append(root)
            continue
        }
        // `enumerator(atPath:)` does not descend symlinked directories, and
        // several checkouts reach shared trees that way, so resolve the root
        // before walking it.
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(atPath: resolved) else {
            die("could not walk \(root)")
        }
        for case let relative as String in walker {
            found.append(resolved + "/" + relative)
        }
    }
    return found.filter { path in
        guard o.extensions.contains(where: { path.hasSuffix("." + $0) }) else { return false }
        return !o.excludes.contains(where: { path.contains($0) })
    }.sorted()
}

struct Site {
    let path: String
    let line: Int
    let code: String
    let guarded: Bool
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())

if argv.contains("-h") || argv.contains("--help") {
    print(usage)
    exit(0)
}

if argv.contains("--self-test") {
    exit(runSelfTest() ? 0 : 1)
}

let options = parse(argv)
if options.match.isEmpty {
    die("nothing to match. Pass --match or --match-regex, or --help.")
}

let files = sourceFiles(options)
// A scan whose corpus is empty reports a clean pass. Refuse instead.
if files.count < options.minFiles {
    die("walked \(files.count) file(s) under \(options.roots.joined(separator: ", ")), "
        + "which is below --min-files \(options.minFiles). A scan that read nothing "
        + "cannot report a pass.")
}

var sites: [Site] = []
var filesWithSites: Set<String> = []
let censusMode = !options.guardBy.isEmpty

for path in files {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    let lines = source.components(separatedBy: "\n")
    let lexed = options.raw ? lines : codeOnly(lines: lines)
    for (index, code) in lexed.enumerated() where options.match.matches(code) {
        let guarded = censusMode && guardOnThePath(lexed: lexed, index: index, guardBy: options.guardBy)
        sites.append(Site(path: path, line: index + 1, code: code.trimmingCharacters(in: .whitespaces),
                          guarded: guarded))
        filesWithSites.insert((path as NSString).lastPathComponent)
    }
}

let reported = censusMode ? sites.filter { !$0.guarded } : sites
var expectationFailed = false
if let expected = options.expectFiles, Set(expected) != filesWithSites {
    expectationFailed = true
}

if options.json {
    var payload: [String: Any] = [
        "filesWalked": files.count,
        "matches": sites.count,
        "reported": reported.count,
        "mode": censusMode ? "census" : (options.failOnMatch ? "lint" : "inventory"),
        "filesWithMatches": filesWithSites.sorted(),
        "sites": reported.map { ["file": $0.path, "line": $0.line, "code": $0.code] }
    ]
    if let expected = options.expectFiles {
        payload["expectFiles"] = expected.sorted()
        payload["expectFilesMatched"] = !expectationFailed
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "{}")
} else if options.countOnly {
    print("files walked: \(files.count)")
    print("matches: \(sites.count) in \(filesWithSites.count) file(s)")
    if censusMode { print("unguarded: \(reported.count)") }
} else {
    for site in reported {
        print("\(site.path):\(site.line): \(site.code)")
    }
    let subject = censusMode
        ? "site(s) matching \(options.match.description) with no \(options.guardBy.description) on the path"
        : "site(s) matching \(options.match.description)"
    print("— \(reported.count) \(subject), over \(files.count) file(s) in \(filesWithSites.count) file(s) with matches")
    if expectationFailed, let expected = options.expectFiles {
        print("— expected matches in exactly \(expected.sorted()), found \(filesWithSites.sorted())")
    }
}

if expectationFailed { exit(1) }
if censusMode { exit(reported.isEmpty ? 0 : 1) }
if options.failOnMatch { exit(sites.isEmpty ? 0 : 1) }
exit(0)

// MARK: - self-test

/// The lexer and scope cases, carried with the tool so a contributor can prove
/// it still reads code as code before trusting a census it printed. Each case
/// pins a shape that a simpler scan gets wrong.
func runSelfTest() -> Bool {
    var failures: [String] = []
    func expect(_ condition: Bool, _ what: String) {
        if !condition { failures.append(what) }
    }

    // Lexing: comments and literals are not code.
    expect(codeOnly("if x { // trailing }").trimmingCharacters(in: .whitespaces) == "if x {",
           "a trailing comment's brace must not survive")
    expect(codeOnly("// whole line {") == "", "a whole-line comment strips to nothing")
    expect(codeOnly("/* block { */ if y {").trimmingCharacters(in: .whitespaces) == "if y {",
           "a single-line block comment strips to nothing")
    expect(codeOnly("if a { b() }") == "if a { b() }", "code survives as itself")
    expect(!codeOnly("let r = #\"he said \"x { y\" done\"#").contains("{"),
           "a raw string's inner quote closes nothing, so its brace stays inside it")

    // A `//` inside a string is not a comment, and a quote inside a comment does
    // not open a string. Stripping them in two passes gets both wrong.
    let token = Predicate(tokens: ["mayStore"])
    expect(token.matches(codeOnly("let u = \"http://x\"; if mayStore { return }")),
           "a URL in a literal must not swallow the code after it")
    expect(!token.matches(codeOnly("// he said \"mayStore\" here")),
           "prose naming a token is not the token")
    expect(!token.matches(codeOnly("doSomething()  // ask mayStore before storing")),
           "a TRAILING comment naming a token is not the token either")

    // A multi-line block comment naming a token: unreachable from a per-line
    // sanitiser by construction, which is why the lexer carries file state.
    let blockComment = codeOnly(lines: [
        "    /* why this matters:",
        "       ask mayStore before storing",
        "     */",
        "    func newArm() {",
        "        announce()",
        "    }"
    ])
    expect(!guardOnThePath(lexed: blockComment, index: 4, guardBy: token),
           "a paragraph naming the guard is not the guard")

    // A `"""` body is prose too, and its braces must not move the arithmetic.
    let stringBody = codeOnly(lines: [
        "    func fulfill() {",
        "        if streaming {",
        "            let css = \"\"\"",
        "            .cls { color: red;",
        "            \"\"\"",
        "            guard mayStore() else { return }",
        "            announce()",
        "        }",
        "        if other {",
        "            announce()",
        "        }",
        "    }"
    ])
    expect(guardOnThePath(lexed: stringBody, index: 6, guardBy: token),
           "the guarded arm is still guarded")
    expect(!guardOnThePath(lexed: stringBody, index: 9, guardBy: token),
           "an unbalanced brace inside a string body must not reach the sibling arm")

    // Scope: a sibling function's guard does not cover this one.
    let siblingFunction = codeOnly(lines: [
        "    func guardedPath() {",
        "        guard mayStore(",
        "            state: s) else { return }",
        "        announce()",
        "    }",
        "",
        "    private func unguardedPath() {",
        "        announce()",
        "    }"
    ])
    expect(guardOnThePath(lexed: siblingFunction, index: 3, guardBy: token),
           "a multi-line guard above the site covers it")
    expect(!guardOnThePath(lexed: siblingFunction, index: 7, guardBy: token),
           "a guard in a sibling function must not cover this one")

    // An early return at the enclosing level DOES cover arms nested below it.
    let earlyReturn = codeOnly(lines: [
        "    func fulfill() {",
        "        if mayStore() == false { return }",
        "        if isAudiobook {",
        "            announce()",
        "        }",
        "        if isPDF {",
        "            announce()",
        "        }",
        "    }"
    ])
    expect(guardOnThePath(lexed: earlyReturn, index: 3, guardBy: token),
           "an early return at the enclosing level covers the first nested arm")
    expect(guardOnThePath(lexed: earlyReturn, index: 6, guardBy: token),
           "...and the second")

    // A guard added below the site cannot retroactively cover it.
    let guardBelow = codeOnly(lines: [
        "    func fulfill() {",
        "        announce()",
        "        guard mayStore() else { return }",
        "    }"
    ])
    expect(!guardOnThePath(lexed: guardBelow, index: 1, guardBy: token),
           "a guard below the site does not cover it")

    // The known limit, asserted as current behaviour so it stays visible. If
    // someone teaches the walk about these lines, this case fails — update it,
    // do not delete it.
    for neutral in ["        } else {", "        } else if other {", "        } catch {"] {
        let s = codeOnly(lines: [
            "    func fulfill() {",
            "        do {",
            "            guard mayStore() else { return }",
            "            announce()",
            neutral,
            "            announce()",
            "        }",
            "    }"
        ])
        expect(guardOnThePath(lexed: s, index: 3, guardBy: token),
               "the first arm is genuinely guarded")
        expect(guardOnThePath(lexed: s, index: 5, guardBy: token),
               "KNOWN LIMIT: \(neutral.trimmingCharacters(in: .whitespaces)) is brace-neutral, "
               + "so the second arm is not distinguished")
    }

    // A regular-expression predicate runs over the same lexed code.
    let regex = Predicate(patterns: [compile("DispatchQueue\\.main\\.sync")])
    expect(regex.matches(codeOnly("        DispatchQueue.main.sync { work() }")),
           "a regex predicate matches code")
    expect(!regex.matches(codeOnly("        // never DispatchQueue.main.sync here")),
           "a regex predicate does not match prose")

    if failures.isEmpty {
        print("self-test: all cases pass")
        return true
    }
    for failure in failures { print("self-test FAILED: \(failure)") }
    print("self-test: \(failures.count) failing case(s)")
    return false
}
