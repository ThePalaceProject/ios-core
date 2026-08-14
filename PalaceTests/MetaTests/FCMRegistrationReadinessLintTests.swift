//
//  FCMRegistrationReadinessLintTests.swift
//  PalaceTests
//
//  Meta-test pinning the PP-4958 ordering contract:
//
//    `NotificationService.updateToken()` MUST await account readiness
//    (`awaitReady`) before it can reach token registration.
//
//  Why this is a structural lint rather than a runtime test: the ordering
//  cannot be driven from a unit test. `Account` is `final`, and
//  `Account+profileDocument.swift` resolves its networking through
//  `AppContainer.production().networkExecutor`, so there is no seam to observe
//  the profile call from. The options were (a) add production surface purely for
//  a test, (b) leave the ordering unpinned, or (c) assert the structure. A prior
//  review rejected (a) as duplicated surface and (b) as unfalsifiable, so this
//  is (c) — zero production cost, and it fails if someone reorders the gate.
//
//  Why it matters: registration ran BEFORE the authentication document loaded,
//  so `Account.details` was nil, `getProfileDocument` returned on its first
//  guard with no network call and no log, and push registration was silently
//  skipped — ~53,000 Crashlytics events across ~6,600 patrons in 30 days, who
//  then never received "your hold is ready". The gate is the fix; this pins it.
//
//  Precedent for the shape: the nine sibling lints in this directory, and the
//  `ws0-inert-quiescence-gate` wall-failure canon requiring a synthetic-violator
//  self-test so the lint cannot silently stop detecting.
//

import XCTest

final class FCMRegistrationReadinessLintTests: XCTestCase {

    private var notificationServicePath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Palace/Notifications/NotificationService.swift")
    }

    /// Strips `//` comment tails so the lint scans CODE, not prose.
    ///
    /// Without this the assertions match their own explanatory comments — the
    /// documented `ratchet-detectors-count-comment-mentions` trap, which this
    /// lint hit on its first run because the gate's comments necessarily name
    /// `getProfileDocument` when explaining the defect.
    private func strippingComments(_ source: String) -> String {
        let withoutComments = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex..<slash.lowerBound]
            }
            .joined(separator: "\n")
        return strippingStringLiterals(withoutComments)
    }

    /// Also blanks `"…"` spans, because a lint that scans CODE must not read
    /// LOG TEXT either.
    ///
    /// The comment-stripping above was added for the documented
    /// `ratchet-detectors-count-comment-mentions` trap. String literals are the
    /// same trap one layer over, and this file hit it: the log line
    /// `"… hasUpdatedToken=\(flag) …"` counted as a second ASSIGNMENT to
    /// `hasUpdatedToken`, so the single-set-site assertion failed against
    /// correct code. Diagnostic text necessarily names the very symbols a lint
    /// watches, so this is a permanent hazard here, not a one-off.
    private func strippingStringLiterals(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var i = 0
        var inMultiline = false
        var inString = false
        var escaped = false
        while i < chars.count {
            let ch = chars[i]
            // A `"""` boundary. Handled BEFORE the single-quote logic, because
            // the naive version toggled three times and left the flag set only
            // to the end of that line — so the multiline literal's CONTENT was
            // scanned as code. `NotificationService.swift` has one (the
            // notification-dump log), and a future diagnostic line inside it
            // naming a watched symbol would fire this lint on correct code:
            // the same trap as the comment and single-line-string cases, one
            // layer further over.
            if !inString, i + 2 < chars.count, ch == "\"", chars[i + 1] == "\"", chars[i + 2] == "\"" {
                inMultiline.toggle()
                i += 3
                continue
            }
            if inMultiline {
                // Keep newlines so line structure (and any brace balance
                // outside the literal) is preserved; drop everything else.
                if ch == "\n" { out.append(ch) }
                i += 1
                continue
            }
            if escaped { escaped = false; if !inString { out.append(ch) }; i += 1; continue }
            if ch == "\\" { escaped = true; if !inString { out.append(ch) }; i += 1; continue }
            if ch == "\"" { inString.toggle(); out.append(ch); i += 1; continue }
            if ch == "\n" { inString = false; out.append(ch); i += 1; continue }
            if !inString { out.append(ch) }
            i += 1
        }
        return out
    }

    /// Extracts the body of `func updateToken()` by brace balance.
    private func updateTokenBody(in source: String) throws -> String {
        let marker = "func updateToken() {"
        let start = try XCTUnwrap(source.range(of: marker),
                                  "updateToken() not found — was it renamed? The readiness contract still needs pinning.")
        var depth = 0
        var body = ""
        for ch in source[start.lowerBound...] {
            body.append(ch)
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return body
    }

    // MARK: - The lint itself

    /// Every check this lint performs, as ONE function returning the names of
    /// the checks a body violates.
    ///
    /// Factored out because the previous shape was inert: the self-tests
    /// re-implemented each comparison inline, so deleting the real ordering
    /// assertion left all three of them green — the exact regression they were
    /// added to catch, one round after it happened. A reviewer caught it. The
    /// sibling `RuntimeQuiescenceLintTests` already had the right shape
    /// (`declaresDirectXCTestCaseSubclass` / `fileViolates` are functions the
    /// self-tests call); this now matches it.
    ///
    /// Returns `[]` for a compliant body.
    static func readinessViolations(inUpdateTokenBody body: String) -> [String] {
        var violations: [String] = []

        // Matches `Task {`, `Task.detached {`, and `Task(priority: .x) {`.
        // Keying on the literal "Task {" reported `no-task` for the other two:
        // it failed CLOSED, but a legitimate refactor to `Task(priority:)` would
        // have been a false positive, and a lint that cries wolf gets deleted.
        let introducer = try! NSRegularExpression(pattern: #"Task(\.detached)?\s*(\([^)]*\))?\s*\{"#)
        guard let m = introducer.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let taskRange = Range(m.range, in: body) else {
            return ["no-task"]
        }
        var depth = 0
        var taskBody = ""
        for ch in body[taskRange.lowerBound...] {
            taskBody.append(ch)
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }

        if !taskBody.contains("awaitReady") {
            violations.append("await-not-in-task")
        }
        if let awaitAt = taskBody.range(of: "awaitReady")?.lowerBound,
           let registerAt = taskBody.range(of: "performTokenRegistration")?.lowerBound,
           awaitAt > registerAt {
            violations.append("register-before-await")
        }
        // Counting form ONLY. There used to be a second, guard-form check here
        // (`!taskBody.contains("performTokenRegistration")`) that appended the
        // same violation name. The two mutually MASKED: deleting either left
        // every self-test green, because whichever survived still fired on the
        // one fixture that exercised the pair. Reviewer-found and confirmed by
        // running each deletion against every fixture. The counting form
        // subsumes the guard form — registration outside the Task means
        // `total > inside` — so the guard form is deleted rather than given a
        // fixture it cannot uniquely earn. A body with NO registration at all
        // is now reported as `register-not-exactly-once`, which is what it
        // actually is.
        let total = body.components(separatedBy: "performTokenRegistration").count - 1
        let inside = taskBody.components(separatedBy: "performTokenRegistration").count - 1
        if total != inside {
            violations.append("register-outside-task")
        }
        if inside != 1 {
            violations.append("register-not-exactly-once")
        }
        if body.contains("getProfileDocument") {
            violations.append("direct-getProfileDocument")
        }
        if !body.contains("awaitReady(timeout:") {
            violations.append("unbounded-await")
        }
        // `try? await …awaitReady` swallows the throw and falls straight through
        // to registration, so a timed-out or failed load registers anyway — the
        // gate is present textually and inert in exactly the failure case it
        // exists for. Production uses `try await` inside a do/catch that returns
        // on every arm. A reviewer found this shape produced zero violations,
        // and worse, the clean-body fixture itself used it.
        if taskBody.contains("try? await") && taskBody.contains("awaitReady") {
            violations.append("await-error-swallowed")
        }
        // `try?` is only ONE spelling of swallowing the readiness error.
        // `do { try await … } catch { }` — an empty or fall-through catch —
        // reaches registration on exactly the path the gate exists for, and
        // round 7 fixed only the `try?` spelling. A reviewer measured the
        // do/catch form at zero violations. DISTINCT violation name on purpose:
        // two checks sharing one name is what let the `register-outside-task`
        // pair mask each other's deletion.
        if !catchBlocksAllReturn(in: taskBody) {
            violations.append("catch-does-not-return")
        }
        return violations
    }

    /// Whether every `catch` inside the awaiting Task returns.
    ///
    /// The contract is that NO readiness failure may fall through to
    /// registration. Production satisfies it by returning on every arm of its
    /// `catch let error as AccountLoadError` switch and on the untyped `catch`.
    /// A body with no `catch` at all is compliant: an uncaught throw exits the
    /// Task, which also never reaches registration.
    /// The test is the block's LAST statement, not whether it CONTAINS a
    /// `return`. `contains` was inert against the only catch shape this file
    /// will ever have: production's typed block holds three returns, so any one
    /// of them going missing was invisible, and a rewrite letting `.quiet` and
    /// `.residual` fall through while `.report` returned also scored clean. The
    /// guard was exercising `catch { }` — a shape production does not have —
    /// rather than the shape actually at risk. Reviewer-measured.
    ///
    /// Every line of sanitized source must have balanced `"` after triple-quote
    /// runs are discounted.
    ///
    /// The sanitizer is a scanner, not a Swift lexer, and a reviewer measured
    /// three ways to defeat it — two spurious violations and, worse, one silent
    /// MISS. Rather than grow a lexer, assert the precondition the scanner
    /// needs: if a line's quotes do not balance, this file's assumptions no
    /// longer hold and the lint must say so loudly instead of quietly scanning
    /// text as code (or code as text).
    /// The 1-based lines whose `"` do not balance after sanitizing.
    ///
    /// A pure function with a red-side fixture, like the nine checks in
    /// `readinessViolations` — it was previously an inline `XCTAssert` loop with
    /// no self-test, which is the same never-observed-red shape this file has
    /// now been bitten by four times.
    ///
    /// No triple-quote discount: `strippingStringLiterals` CONSUMES `"""` runs,
    /// so none survive into this function's only input. That branch was measured
    /// dead and deleted rather than left as decoration.
    static func unbalancedQuoteLines(in sanitized: String) -> [Int] {
        sanitized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.element.filter { $0 == "\"" }.count % 2 != 0 }
            .map { $0.offset + 1 }
    }

    /// Whether a `catch` block's last statement is `return`.
    static func blockEndsInReturn(_ block: String) -> Bool {
        let inner = block.dropFirst().dropLast()   // strip the outer braces
        let statements = inner
            .split(separator: "\n")
            .flatMap { $0.split(separator: ";") }   // `log(); return` is two statements
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = statements.last else { return false }   // empty catch
        // Exact, or `return <value>`. `hasPrefix("return")` alone was wrong in
        // BOTH directions, measured by a reviewer: `returnedEarly()` scored
        // compliant, and the idiomatic `catch { log(); return }` scored as a
        // violation — a false positive in the file whose own principle is that
        // a lint which cries wolf gets deleted.
        return last == "return" || last.hasPrefix("return ")
    }

    static func catchBlocksAllReturn(in taskBody: String) -> Bool {
        var cursor = taskBody.startIndex
        while let clause = taskBody.range(of: "catch", range: cursor..<taskBody.endIndex) {
            guard let open = taskBody.range(of: "{", range: clause.upperBound..<taskBody.endIndex) else {
                return false
            }
            var depth = 0
            var block = ""
            for ch in taskBody[open.lowerBound...] {
                block.append(ch)
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            if !blockEndsInReturn(block) { return false }
            cursor = clause.upperBound
        }
        return true
    }

    // MARK: - The production source must be clean

    func testUpdateToken_satisfiesEveryReadinessCheck() throws {
        let source = strippingComments(try String(contentsOf: notificationServicePath, encoding: .utf8))
        XCTAssertEqual(Self.unbalancedQuoteLines(in: source), [],
                       "quotes do not balance after sanitizing — the lint's scanner cannot be trusted on this file, and a silent mis-scan is exactly how it would stop detecting")
        let body = try updateTokenBody(in: source)

        XCTAssertEqual(Self.readinessViolations(inUpdateTokenBody: body), [],
                       "NotificationService.updateToken() violates the PP-4958 readiness contract")
    }

    // MARK: - Synthetic violators
    //
    // Each calls `readinessViolations` and asserts the SPECIFIC check that
    // should fire, so deleting a check inside that function turns one of these
    // red. Per the `ws0-inert-quiescence-gate` canon: a gate that cannot be
    // shown failing is not a gate.

    /// Registration lives outside the awaiting Task. Textual ordering reads
    /// "await first" and passes a naive check; this is PP-4958 fully restored.
    func testLint_detectsRegistrationOutsideTheAwaitingTask() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                _ = try? await account.awaitReady(timeout: 30)
            }
            performTokenRegistration(for: account)
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        XCTAssertTrue(Self.readinessViolations(inUpdateTokenBody: body).contains("register-outside-task"),
                      "the containment check must flag registration that lives outside the awaiting Task")
    }

    /// Contained but mis-ordered. Passes a containment-only check and is
    /// PP-4958 intact — this is the shape a round-4 regression let through.
    func testLint_detectsRegistrationBeforeAwaitInsideTheTask() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                self?.performTokenRegistration(for: account)
                _ = try? await account.awaitReady(timeout: 45)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        let violations = Self.readinessViolations(inUpdateTokenBody: body)
        XCTAssertTrue(violations.contains("register-before-await"),
                      "the ordering check must flag register-before-await inside the Task; got \(violations)")
        XCTAssertFalse(violations.contains("register-outside-task"),
                       "precondition: this violator IS contained — that is why containment alone is insufficient")
    }

    /// A swallowed throw: the gate is present but inert in the failure case it
    /// exists for, because `try?` falls through to registration anyway.
    func testLint_detectsSwallowedReadinessError() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                _ = try? await account.awaitReady(timeout: 45)
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        XCTAssertTrue(Self.readinessViolations(inUpdateTokenBody: body).contains("await-error-swallowed"),
                      "a `try?` readiness wait registers anyway when the wait fails — the gate must not be bypassable by swallowing its error")
    }

    /// A do/catch whose catch does NOT return. The gate is present, `try` is
    /// not `try?`, and the readiness error is still swallowed — execution falls
    /// out of the catch straight into registration, exactly on the timeout and
    /// load-failure paths the gate exists for. Round 7 closed the `try?`
    /// spelling of this and left the do/catch spelling open; a reviewer
    /// measured it at zero violations.
    func testLint_detectsACatchThatFallsThroughToRegistration() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                do {
                    _ = try await account.awaitReady(timeout: 45)
                } catch {
                }
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        let violations = Self.readinessViolations(inUpdateTokenBody: body)
        XCTAssertTrue(violations.contains("catch-does-not-return"),
                      "a catch that does not return reaches registration precisely when readiness FAILED; got \(violations)")
        XCTAssertFalse(violations.contains("await-error-swallowed"),
                       "precondition: this violator uses `try`, not `try?` — that is why the try? check alone is insufficient")
    }

    /// The shape production actually has: a typed catch with several arms, one
    /// of which falls through instead of returning. `contains("return")` scored
    /// this clean because the other arms return — so the check was inert
    /// against the only catch this file will ever contain, while passing on the
    /// synthetic empty-catch violator. Reviewer-measured.
    func testLint_detectsACatchWhoseLastArmFallsThrough() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                do {
                    _ = try await account.awaitReady(timeout: 45)
                } catch let error as AccountLoadError {
                    if error == .evicted {
                        return
                    }
                    Log.warn(#file, "readiness failed")
                }
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        XCTAssertTrue(Self.readinessViolations(inUpdateTokenBody: body).contains("catch-does-not-return"),
                      "a catch arm that logs and falls through reaches registration on exactly the failure it just logged")
    }

    /// A Task introduced with a priority must be recognised as the awaiting
    /// Task, not reported as "no Task at all". Fails-closed is still a false
    /// positive, and a lint that cries wolf on a legitimate refactor gets
    /// deleted.
    func testLint_recognisesATaskWithAPriority() throws {
        let compliant = """
        func updateToken() {
            Task(priority: .utility) { [weak self] in
                do {
                    _ = try await account.awaitReady(timeout: 45)
                } catch {
                    return
                }
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(compliant))
        XCTAssertEqual(Self.readinessViolations(inUpdateTokenBody: body), [],
                       "Task(priority:) is still the awaiting Task — reporting no-task here is a false positive")
    }

    /// The unbounded overload: an `awaitReady()` behind this background path is
    /// the HelpSpot #18414 load-forever wedge.
    func testLint_detectsUnboundedAwait() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                _ = try? await account.awaitReady()
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        XCTAssertTrue(Self.readinessViolations(inUpdateTokenBody: body).contains("unbounded-await"),
                      "the bounded-overload check must flag a bare awaitReady()")
    }

    /// Registration twice per attempt — duplicate /patrons/me/ + PUT traffic.
    func testLint_detectsRegistrationMoreThanOnce() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                _ = try? await account.awaitReady(timeout: 30)
                self?.performTokenRegistration(for: account)
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        XCTAssertTrue(Self.readinessViolations(inUpdateTokenBody: body).contains("register-not-exactly-once"),
                      "the exactly-once check must flag a second registration call")
    }

    /// Bypassing the gate entirely by calling the profile fetch inline.
    func testLint_detectsDirectProfileFetch() throws {
        let violator = """
        func updateToken() {
            account.getProfileDocument { _ in }
            Task { [weak self] in
                _ = try? await account.awaitReady(timeout: 30)
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        XCTAssertTrue(Self.readinessViolations(inUpdateTokenBody: body).contains("direct-getProfileDocument"),
                      "the lint must flag updateToken() calling getProfileDocument directly")
    }

    /// No awaiting Task at all — the gate simply deleted. Trivial to reach by
    /// reverting the fix, and nothing exercised this check before: it was one
    /// of four whose removal left every self-test green.
    func testLint_detectsAGateWithNoTaskAtAll() throws {
        let violator = """
        func updateToken() {
            performTokenRegistration(for: account)
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        XCTAssertTrue(Self.readinessViolations(inUpdateTokenBody: body).contains("no-task"),
                      "a body with no awaiting Task has no gate at all and must be flagged")
    }

    /// Registration inside ITS OWN Task, with the readiness wait parked in a
    /// SECOND, unrelated Task. This compiles, reads as though a gate is
    /// present, and restores PP-4958 completely — registration never waits for
    /// anything. `await-not-in-task` is the only check that catches it, and
    /// before this test nothing exercised that check, so deleting it left the
    /// whole suite green.
    func testLint_detectsAwaitParkedInADifferentTask() throws {
        let violator = """
        func updateToken() {
            Task { [weak self] in
                self?.performTokenRegistration(for: account)
            }
            Task {
                _ = try await account.awaitReady(timeout: 45)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(violator))
        let violations = Self.readinessViolations(inUpdateTokenBody: body)
        XCTAssertTrue(violations.contains("await-not-in-task"),
                      "the readiness wait must live in the SAME Task that registers; got \(violations)")
        XCTAssertFalse(violations.contains("register-outside-task"),
                       "precondition: registration IS inside a Task here — that is why containment alone cannot catch this shape")
    }

    /// A compliant body must produce NO violations — the clean-diff assertion
    /// the CI canon requires, so a check that rejects everything cannot ship.
    func testLint_compliantBodyProducesNoViolations() throws {
        let compliant = """
        func updateToken() {
            Task { [weak self] in
                do {
                    _ = try await account.awaitReady(timeout: 45)
                } catch {
                    return
                }
                self?.performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(compliant))
        XCTAssertEqual(Self.readinessViolations(inUpdateTokenBody: body), [],
                       "a compliant body must pass, or every future edit is a false positive")
    }

    /// A multiline `"""` literal whose CONTENT names watched symbols must not
    /// trip the lint. The single-line-string fix left this open: the naive
    /// sanitizer toggled on each of the three quotes and reset at the newline,
    /// so the literal's body was scanned as code. Production has such a literal
    /// today (the notification dump), and diagnostic text necessarily names the
    /// symbols a lint watches.
    func testLint_ignoresMultilineStringLiteralContent() throws {
        let compliant = """
        func updateToken() {
            Task { [weak self] in
                do {
                    _ = try await account.awaitReady(timeout: 45)
                } catch {
                    return
                }
                self?.performTokenRegistration(for: account)
            }
            Log.info(#file, \"\"\"
              debugging: currentAccount?.hasUpdatedToken = true and getProfileDocument
            \"\"\")
        }
        """
        let body = try updateTokenBody(in: strippingComments(compliant))
        XCTAssertEqual(Self.readinessViolations(inUpdateTokenBody: body), [],
                       "text inside a multiline literal is not code — scanning it makes every explanatory log line a false positive")
    }

    /// A wrapped call site — what a formatter produces for a long argument —
    /// must not slip past. Before the count pin, injecting the cross-account
    /// defect here made the defective call VANISH from the match set while the
    /// sibling compliant call kept `calls.isEmpty` false, so every assertion
    /// passed. Absence reading as success, in the guard added to close exactly
    /// that class one round earlier.
    func testCallSiteCensus_anUnparseableSpellingFailsInsteadOfVanishing() throws {
        // RED side: `for : account` — a space before the colon, which the regex
        // cannot read. It must show up as a COUNT mismatch. Without this the
        // count pin had only a passing-direction fixture and could not be
        // observed failing.
        let unparseable = """
        private func markTokenRegistered(for account: Account) {
            account.hasUpdatedToken = true
        }
        func a() {
            self.markTokenRegistered(for : account)
        }
        """
        let bad = try Self.callSiteCensus(in: unparseable)
        XCTAssertEqual(bad.occurrences, 2, "precondition: declaration plus one call")
        XCTAssertNotEqual(bad.parsed.count, bad.occurrences - 1,
                          "a spelling the regex cannot parse must break the count, or it vanishes from the sample and the check passes on a defect")

        // GREEN side, including the WRAPPED shape a formatter produces — that
        // one must be parsed, and its argument seen as the violation it is.
        let wrapped = """
        private func markTokenRegistered(for account: Account) {
            account.hasUpdatedToken = true
        }
        func a() {
            self.markTokenRegistered(for: account)
        }
        func b() {
            self.markTokenRegistered(
                for: self.accountsManager.currentAccount!
            )
        }
        """
        let good = try Self.callSiteCensus(in: wrapped)
        XCTAssertEqual(good.parsed.count, good.occurrences - 1,
                       "the wrapped call site must be PARSED, not skipped — that is the whole point of the count pin")
        XCTAssertTrue(good.parsed.contains { $0 != "account" },
                      "the wrapped call passes currentAccount! and must be visible as a violation")
    }

    /// The quote-balance precondition must be observable failing.
    func testUnbalancedQuoteLines_reportsTheOffendingLine() {
        let broken = "let a = 1\nlet b = \"unterminated\nlet c = 3"
        XCTAssertEqual(Self.unbalancedQuoteLines(in: broken), [2],
                       "an odd quote count must be reported with its line, or the scanner's precondition is unfalsifiable")
        XCTAssertEqual(Self.unbalancedQuoteLines(in: "let a = 1\nlet b = 2"), [],
                       "balanced source must report nothing, or every file is a false positive")
    }

    /// Every parsed `markTokenRegistered(for:)` argument, plus how many times
    /// the symbol occurs at all.
    ///
    /// ONE function, so the production check and its fixture cannot drift. They
    /// previously held byte-identical copies of this regex, which meant the
    /// fixture could not protect the check: deleting `\s*` from the real one
    /// killed nothing, because production's call sites are single-line and the
    /// fixture consulted its own copy. Fourth instance of the same
    /// never-observed-red shape, and the reason the rule is now "one pure
    /// function, one red-side fixture" rather than "add another assertion".
    ///
    /// `occurrences` is the independent census: a spelling the regex cannot
    /// read drops out of `parsed` but still counts here, so the mismatch fails
    /// the test instead of silently shrinking the sample.
    static func callSiteCensus(in source: String) throws -> (parsed: [String], occurrences: Int) {
        let pattern = try NSRegularExpression(pattern: #"markTokenRegistered\(\s*for:\s*([^)]*)\)"#)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let parsed = matches.compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r]).trimmingCharacters(in: .whitespaces)
        }
        return (parsed, source.components(separatedBy: "markTokenRegistered").count - 1)
    }

    // MARK: - The cross-account latch (round-2 fix, previously untested)

    /// `markTokenRegistered` must latch the account the attempt was made FOR,
    /// never `currentAccount`.
    ///
    /// The readiness wait made registration asynchronous, so a library switch
    /// can land between starting an attempt for account A and finishing it.
    /// `currentAccount?.hasUpdatedToken = true` at that point marks account B
    /// registered when only A was, and `AccountsManager` clears the flag on the
    /// OUTGOING account only — so B stays latched-but-unregistered and never
    /// retries. That is the same silent-suppression class PP-4958 itself is.
    ///
    /// A structural check because the write has no observable seam: `Account`
    /// is `final` and `hasUpdatedToken` is a plain stored property. Reviewer
    /// noted the round-2 fix shipped with no test of any kind.
    func testMarkTokenRegistered_neverLatchesTheCurrentAccount() throws {
        let source = strippingComments(try String(contentsOf: notificationServicePath, encoding: .utf8))

        // Keying on the single spelling `currentAccount?.hasUpdatedToken =` was
        // a syntax standing in for a semantic: a reviewer measured two
        // re-spellings of the IDENTICAL defect at zero hits —
        // `let cur = accountsManager.currentAccount; cur?.hasUpdatedToken = true`
        // and `markTokenRegistered(for: accountsManager.currentAccount!)`.
        // So assert the invariant instead: this file contains exactly ONE
        // assignment to `hasUpdatedToken`, it lives inside
        // `markTokenRegistered(for:)`, and that function's body never mentions
        // `currentAccount` — which no re-spelling can satisfy.
        let assignment = try NSRegularExpression(pattern: #"hasUpdatedToken\s*=(?!=)"#)
        let hits = assignment.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertEqual(hits.count, 1,
                       "exactly one site may latch hasUpdatedToken; more than one means the success contract has multiple set-sites again")

        let marker = "private func markTokenRegistered(for account: Account) {"
        let start = try XCTUnwrap(source.range(of: marker),
                                  "markTokenRegistered(for:) not found — was it renamed or reverted to a no-argument form?")
        var depth = 0
        var latchBody = ""
        for ch in source[start.lowerBound...] {
            latchBody.append(ch)
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }

        XCTAssertEqual(latchBody.components(separatedBy: "hasUpdatedToken").count - 1, 1,
                       "the one hasUpdatedToken assignment must be the one inside markTokenRegistered(for:)")
        XCTAssertFalse(latchBody.contains("currentAccount"),
                       "markTokenRegistered must latch the account it was PASSED — naming currentAccount in its body reintroduces the cross-account latch regardless of how the write is spelled")

        // The remaining spelling: keep the body clean and pass the wrong thing
        // IN — `markTokenRegistered(for: accountsManager.currentAccount!)`.
        // A reviewer measured that one at zero hits against the previous check,
        // so pin the argument too. Every call site must hand over the account
        // the attempt captured.
        // `\s*` after the paren, because a formatter wrapping a long argument
        // produces `markTokenRegistered(\n    for: …\n)`. But the whitespace is
        // the SMALLER half of this fix. The larger half: a call site the regex
        // cannot parse DISAPPEARS from the match set rather than failing the
        // test, and the sibling compliant call keeps `calls.isEmpty` false — so
        // absence read as success. A reviewer proved it by wrapping one of the
        // two call sites around the cross-account defect and watching every
        // assertion here pass. So pin the COUNT against an independent census:
        // every occurrence of the symbol except its declaration must be a call
        // this regex actually parsed.
        let census = try Self.callSiteCensus(in: source)
        XCTAssertEqual(census.parsed.count, census.occurrences - 1,
                       "every markTokenRegistered occurrence except the declaration must parse as a call site — a spelling this regex cannot read would otherwise vanish from the sample instead of failing this test")
        XCTAssertFalse(census.parsed.isEmpty, "no markTokenRegistered(for:) call sites found — was the success path removed?")
        for argument in census.parsed {
            XCTAssertEqual(argument, "account",
                           "markTokenRegistered must be handed the captured account, not \(argument) — resolving the current account at the CALL site reintroduces the cross-account latch just as surely as writing it in the body")
        }
    }

    /// A body whose only mention of the forbidden call is in a COMMENT must
    /// pass. The lint failed exactly this way on its first run — the documented
    /// `ratchet-detectors-count-comment-mentions` trap.
    func testLint_ignoresCommentMentions() throws {
        let commentOnly = """
        func updateToken() {
            // explains why getProfileDocument must not be called here
            Task {
                _ = try await account.awaitReady(timeout: 30)
                performTokenRegistration(for: account)
            }
        }
        """
        let body = try updateTokenBody(in: strippingComments(commentOnly))
        XCTAssertEqual(Self.readinessViolations(inUpdateTokenBody: body), [],
                       "a comment mention must not trip the lint, or every explanatory comment becomes a false positive")
    }
}
