import XCTest
@testable import TriageBotCore

/// Response quality + classification accuracy benchmark.
///
/// Unlike the unit/chaos tests, these aren't pass/fail gates — they're a
/// **measurement** of how well the bot would serve real Palace users. Each
/// case is a realistic user input with a ground-truth label: either "this
/// SHOULD match KI-NNNN" or "this SHOULD escalate (no known issue)".
///
/// The corpus is drawn from May 2026 HelpSpot triage (real ticket
/// descriptions documented in MEMORY.md "Read first" + PR #1018 / PR #1019
/// retros) plus the paraphrasings a non-technical patron would actually use.
///
/// Three measurements:
///
///   1. **Recall**  — % of cases that SHOULD match where the classifier
///      did suggest the right entry. Misses here are users who would type
///      a real problem and not get the workaround they should have.
///
///   2. **Precision**  — % of cases the classifier flagged as a match that
///      were actually the RIGHT match (vs wrong entry). False positives
///      here are users who get told "this is fixed in 3.2.0" when their
///      issue is actually something else — worse than no match.
///
///   3. **Negative rejection** — % of cases that SHOULD escalate (novel
///      issues, off-topic, malformed) that the classifier correctly did
///      NOT match. False positives here misdirect the user.
///
/// When this benchmark regresses below the published targets, treat it as
/// a signal to inspect the affected KI's keywords or add new ones — not as
/// a hard CI failure.
final class ResponseQualityTests: XCTestCase {

    // Per-corpus targets the demo build should clear. Calibrated from the
    // hand-curated May 2026 dataset; raise as the KB grows.
    static let recallTarget: Double = 0.75       // bot finds ≥75% of in-KB issues
    static let precisionTarget: Double = 0.90    // when bot DOES match, it's right ≥90% of the time
    static let rejectionTarget: Double = 0.85    // bot correctly escalates ≥85% of novel issues

    // MARK: - Corpus

    /// Ground-truth expectation per case.
    enum Expectation: Equatable {
        case shouldMatch(entryId: String)
        case shouldEscalate
    }

    struct Case {
        let userText: String
        let category: KBCategory?
        let context: ContextSnapshot?
        let expect: Expectation
        let source: String   // where the input came from — real ticket id, paraphrase, etc.
    }

    // Real Palace Marketplace context — used by cases that need distributor
    // filter to engage.
    private static let marketplaceContext = ContextSnapshot(
        appVersion: "3.0.3",
        appBuild: "478",
        osVersion: "26.4.2",
        deviceModel: "iPhone17,2",
        distributor: "palace_marketplace"
    )

    private static let openAccessContext = ContextSnapshot(
        appVersion: "3.0.3",
        appBuild: "478",
        osVersion: "26.4.2",
        deviceModel: "iPhone17,2",
        distributor: "open_access"
    )

    // The full corpus. Each entry is realistic — verbatim ticket text where
    // possible, paraphrasings elsewhere.
    private static let corpus: [Case] = [

        // === KI-2026-001 audiobook first-open hang ===

        Case(userText: "my audiobook keeps spinning and won't play the first time I open it",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "HelpSpot 17964 (Carol) verbatim shape"),

        Case(userText: "audiobook just sits there spinning, nothing happens when I tap play",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "paraphrase — 'sits there' is a real patron phrasing"),

        Case(userText: "the audiobook won't play, just hangs",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "HelpSpot 17929 (Kelly)"),

        Case(userText: "tapped play and the audiobook is stuck loading forever",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "paraphrase — 'stuck loading'"),

        // Negative for KI-001 — symptom matches but distributor doesn't
        Case(userText: "audiobook won't play, the spinner spins forever",
             category: .audiobook, context: openAccessContext,
             expect: .shouldEscalate,
             source: "Open Access user — KI-001 is Marketplace-only"),

        // === KI-2026-002 LCP continuation crash ===

        Case(userText: "Palace crashed when I switched libraries while my audiobook was playing",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-002-lcp-continuation-misuse"),
             source: "PP-4438 reproduction script"),

        Case(userText: "the app crashed mid-audiobook after I changed library",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-002-lcp-continuation-misuse"),
             source: "paraphrase"),

        // === KI-2026-003 sign-in placeholder contrast ===

        Case(userText: "I can't sign in — the field looks grayed out and I don't know where to type",
             category: .signin, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-003-signin-placeholder-contrast"),
             source: "HelpSpot 17923 (Drake) verbatim shape"),

        Case(userText: "where do I type my barcode, the fields look disabled",
             category: .signin, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-003-signin-placeholder-contrast"),
             source: "paraphrase — 'fields look disabled'"),

        Case(userText: "sign in screen has grayed out text in the boxes",
             category: .signin, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-003-signin-placeholder-contrast"),
             source: "paraphrase"),

        // === KI-2026-004 wrong library (Palace Bookshelf) ===

        Case(userText: "These aren't my books, I'm at the wrong library, can't find my titles",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-004-wrong-library-palace-bookshelf"),
             source: "HelpSpot 17957 (Carlton) verbatim shape"),

        Case(userText: "I see demo books not my library's collection",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-004-wrong-library-palace-bookshelf"),
             source: "paraphrase — 'demo books'"),

        Case(userText: "Where is my library? I see Bookshelf instead",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-004-wrong-library-palace-bookshelf"),
             source: "paraphrase"),

        // === KI-2026-005 CarPlay SIGABRT ===

        Case(userText: "Palace crashes the moment I plug into CarPlay",
             category: .audiobook, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-005-carplay-sigabrt"),
             source: "PR #968 reproduction"),

        Case(userText: "app crashes whenever I connect to car play with an audiobook",
             category: .audiobook, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-005-carplay-sigabrt"),
             source: "paraphrase"),

        // === KI-2026-006 hold-ready desync ===

        Case(userText: "got a notification that my hold is ready but it's not in my holds list",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-006-hold-ready-desync"),
             source: "HelpSpot 17960 (Derryl) verbatim shape"),

        Case(userText: "hold ready notification but the holds disappeared",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-006-hold-ready-desync"),
             source: "HelpSpot 17971 (Heather)"),

        // === KI-2026-007 LCP PDF fail to open ===

        Case(userText: "PDF won't open, just shows a blank screen",
             category: .reader, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-007-lcp-pdf-fail-to-open"),
             source: "PP-4454 reproduction"),

        Case(userText: "my pdf is stuck on the cover and won't open",
             category: .reader, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-007-lcp-pdf-fail-to-open"),
             source: "paraphrase"),

        // === KI-2026-008 download troubleshooting ===

        Case(userText: "Book won't download, no progress at all",
             category: .download, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-008-download-no-network"),
             source: "common HelpSpot pattern"),

        Case(userText: "download stuck, hasn't moved in 20 minutes",
             category: .download, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-008-download-no-network"),
             source: "paraphrase"),

        // === SHOULD ESCALATE — novel symptoms ===

        Case(userText: "my reader font size resets to defaults every time I open a book",
             category: .reader, context: nil,
             expect: .shouldEscalate,
             source: "novel — no KI entry exists for this"),

        Case(userText: "the highlights I made yesterday are gone",
             category: .reader, context: nil,
             expect: .shouldEscalate,
             source: "novel — bookmark/annotation loss"),

        Case(userText: "when I rotate my iPad the layout looks broken",
             category: .reader, context: nil,
             expect: .shouldEscalate,
             source: "novel — UI layout"),

        Case(userText: "audio narration speeds up by itself randomly",
             category: .audiobook, context: nil,
             expect: .shouldEscalate,
             source: "novel — playback rate quirk"),

        Case(userText: "library cover art is missing on a bunch of titles",
             category: .library, context: nil,
             expect: .shouldEscalate,
             source: "novel — cover-art loading"),

        // === SHOULD ESCALATE — off-topic / nonsense ===

        Case(userText: "Can you recommend a good book?",
             category: .other, context: nil,
             expect: .shouldEscalate,
             source: "off-topic — bot is for issues, not recommendations"),

        Case(userText: "I want to cancel my library card",
             category: .other, context: nil,
             expect: .shouldEscalate,
             source: "off-topic — account-management, route to library"),

        Case(userText: "Hello",
             category: nil, context: nil,
             expect: .shouldEscalate,
             source: "minimal input"),

        // === SHOULD ESCALATE — adversarial near-misses ===

        Case(userText: "I am a Bearer of good news, my audiobook plays perfectly",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldEscalate,
             source: "decoy — keywords absent but trigger words present"),

        Case(userText: "Just wanted to say the new audiobook chapter navigation is great",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldEscalate,
             source: "positive feedback — must not match a 'fix' card"),

        // === Mined from HelpSpot — May 2026 batch ===
        // Each entry is anonymized (no names, emails, library names, titles).
        // Source field records the actual support resolution where available
        // so the .shouldMatch / .shouldEscalate label can be validated
        // against what triagers really did.

        Case(userText: "hold became available but the audiobook won't load when I tap it, then the loan disappears",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "HelpSpot 17964 — Marketplace audiobook won't load on iOS 3.0.3 after hold fulfilled; resolved by engineer touching install (matches KI-001 fix train)"),

        Case(userText: "audiobooks won't download after I uninstalled and reinstalled and rebooted",
             category: .download, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-008-download-no-network"),
             source: "HelpSpot 17964 — download-failure phrasing; routes to KI-008 since user picked Download category (not audiobook playback)"),

        Case(userText: "library staff reports the audiobook a patron checked out will not play and reinstall did not help",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "HelpSpot 17929 — library staff escalation; resolved by pointing at App Store hotfix awaiting approval"),

        Case(userText: "the book I downloaded on my phone doesn't appear on my iPad",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-004-wrong-library-palace-bookshelf"),
             source: "HelpSpot 17957 — patron's iPad on Palace Bookshelf demo, not their real library; fix was Add Library + sign in on iPad"),

        Case(userText: "the sign-in page shows grayed-out boxes and I'm never prompted to enter my card",
             category: .signin, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-003-signin-placeholder-contrast"),
             source: "HelpSpot 17923 — patron read low-contrast placeholders as disabled fields; support clarified placeholders are by design"),

        Case(userText: "I keep getting notifications that my hold is ready but when I open holds the book is still on hold",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-006-hold-ready-desync"),
             source: "HelpSpot 17960 — iOS 26.4.2 audiobook holds; hold-ready notification fires but list shows title still pending"),

        Case(userText: "I have been at position 1 in the queue for months on several holds but they never become available to me",
             category: .library, context: nil,
             expect: .shouldEscalate,
             source: "HelpSpot 17971 — DISTINCT from KI-006: no hold-ready notification, patron stuck at position 1 across multiple titles; CM-side queue stall, must escalate"),

        Case(userText: "I get an invalid credentials error about a quarter of the time when I try to borrow an audiobook",
             category: .signin, context: nil,
             expect: .shouldEscalate,
             source: "HelpSpot 17984 — Android patron, intermittent 401 on borrow; resolution found bad credentials on library's own catalog (account-side)"),

        Case(userText: "my barcode and password are correct but the app gives me a login error on Android",
             category: .signin, context: nil,
             expect: .shouldEscalate,
             source: "HelpSpot 17917 — Android user; platform mismatch for iOS triage bot"),

        Case(userText: "I tap the play button on the audiobook and it just blinks, no sound",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "HelpSpot 17989 — Marketplace audiobook play-button no-op; assigned to support, still open. Matches KI-001 engine-doesn't-start symptom"),

        Case(userText: "audiobook played fine first checkout, returned it, checked out again and now audio refuses to play even after delete and reinstall and re-login",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldEscalate,
             source: "HelpSpot 17981 — KB GAP: post-recheckout permanent failure, distinct from KI-001 first-open hang. Needs new KI"),

        Case(userText: "trying to download an ebook and it never works after I toggled wifi and reinstalled the app",
             category: .download, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-008-download-no-network"),
             source: "HelpSpot 17976 — download stuck after wifi toggle + reinstall; closed with version+logout/login template, matches KI-008 guidance"),

        Case(userText: "the app stops playing and the audiobook will not load properly even after deleting the app and redownloading",
             category: .audiobook, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "HelpSpot 17959 — audiobook won't load after reinstall; closed with standard troubleshooting"),

        Case(userText: "trying to add the demo bookshelf library to my account and I get an error that my email is already in use",
             category: .signin, context: nil,
             expect: .shouldEscalate,
             source: "HelpSpot 17915 — KB GAP: virtual library card sign-up cross-library email collision; required staff to manually provision card. No self-serve workaround"),

        Case(userText: "I want to add a second library and the Add Library search does not show any additional libraries beyond what I already have",
             category: .library, context: nil,
             expect: .shouldEscalate,
             source: "HelpSpot 17930 — KB GAP: stale Add Library registry cache; fix was pull-to-refresh. Should be its own KI"),

        Case(userText: "trying to sign up for a virtual library card and getting an error message",
             category: .signin, context: nil,
             expect: .shouldEscalate,
             source: "HelpSpot 17904 — VLC sign-up error; resolution required staff to provision barcode + clarify mobile-only access. Off-app workflow"),

        Case(userText: "I checked out a book on my phone and it opens fine but on my iPad it still shows as reserved with me next in line on the hold list",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-006-hold-ready-desync"),
             source: "HelpSpot 17835 — second device shows title still on holds list after checkout on first; closed with sign-out/sign-in advice"),

        Case(userText: "everyone at our library is getting an error when they try to open or listen to a book after our ILS server migration",
             category: .other, context: nil,
             expect: .shouldEscalate,
             source: "HelpSpot 17871 — KB GAP: library-staff-facing infrastructure event (ILS IP change); resolved server-side by Palace support. No patron-self-serve path"),
    ]

    // MARK: - Recall (in-KB issues correctly matched)

    func testRecall_meetsTarget() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()

        let positiveCases = Self.corpus.filter {
            if case .shouldMatch = $0.expect { return true }
            return false
        }

        var hits = 0
        var misses: [(Case, ClassificationResult)] = []

        for c in positiveCases {
            let result = classifier.classify(
                userText: c.userText,
                category: c.category,
                context: c.context,
                knowledgeBase: kb
            )
            if case .shouldMatch(let expectedId) = c.expect,
               case .suggest(let actualId) = result.decision,
               expectedId == actualId {
                hits += 1
            } else {
                misses.append((c, result))
            }
        }

        let recall = Double(hits) / Double(positiveCases.count)
        if !misses.isEmpty {
            print("[recall] \(hits)/\(positiveCases.count) = \(String(format: "%.0f%%", recall * 100))")
            for (c, r) in misses {
                print("  MISS: '\(c.userText)' (\(c.source)) → \(r.decision)")
            }
        }
        XCTAssertGreaterThanOrEqual(
            recall, Self.recallTarget,
            "Recall \(recall) below target \(Self.recallTarget). \(misses.count) cases the bot failed to match. Inspect keyword coverage."
        )
    }

    // MARK: - Precision (when bot matches, it's the RIGHT match)

    func testPrecision_meetsTarget() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()

        var trueSuggests = 0
        var falseSuggests: [(Case, ClassificationResult)] = []

        for c in Self.corpus {
            let result = classifier.classify(
                userText: c.userText,
                category: c.category,
                context: c.context,
                knowledgeBase: kb
            )
            if case .suggest(let actualId) = result.decision {
                if case .shouldMatch(let expectedId) = c.expect, expectedId == actualId {
                    trueSuggests += 1
                } else {
                    falseSuggests.append((c, result))
                }
            }
        }

        let totalSuggests = trueSuggests + falseSuggests.count
        guard totalSuggests > 0 else { return XCTFail("Classifier produced zero suggests across corpus") }
        let precision = Double(trueSuggests) / Double(totalSuggests)
        if !falseSuggests.isEmpty {
            print("[precision] \(trueSuggests)/\(totalSuggests) = \(String(format: "%.0f%%", precision * 100))")
            for (c, r) in falseSuggests {
                print("  FALSE+: '\(c.userText)' (\(c.source)) → \(r.decision), expected \(c.expect)")
            }
        }
        XCTAssertGreaterThanOrEqual(
            precision, Self.precisionTarget,
            "Precision \(precision) below target \(Self.precisionTarget). False suggests = misdirection."
        )
    }

    // MARK: - Negative rejection (novel issues correctly escalate)

    func testRejection_meetsTarget() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()

        let negativeCases = Self.corpus.filter { $0.expect == .shouldEscalate }

        var rejected = 0
        var falseSuggests: [(Case, ClassificationResult)] = []

        for c in negativeCases {
            let result = classifier.classify(
                userText: c.userText,
                category: c.category,
                context: c.context,
                knowledgeBase: kb
            )
            if case .escalate = result.decision {
                rejected += 1
            } else if case .disambiguate = result.decision {
                // Counted as rejection — disambiguation is honest "I'm not sure"
                rejected += 1
            } else {
                falseSuggests.append((c, result))
            }
        }

        let rejection = Double(rejected) / Double(negativeCases.count)
        if !falseSuggests.isEmpty {
            print("[rejection] \(rejected)/\(negativeCases.count) = \(String(format: "%.0f%%", rejection * 100))")
            for (c, r) in falseSuggests {
                print("  OVER-MATCH: '\(c.userText)' (\(c.source)) → \(r.decision)")
            }
        }
        XCTAssertGreaterThanOrEqual(
            rejection, Self.rejectionTarget,
            "Rejection \(rejection) below target \(Self.rejectionTarget). Novel issues being misdirected to a KB workaround."
        )
    }

    // MARK: - Per-KB-entry workaround quality

    /// Each entry's `userFacingWorkaround` is what real patrons read. This
    /// test enforces structural quality bars; the manual scoring (Specificity
    /// / Honesty / Expectation-setting / Tone) lives in the test report.
    func testWorkaroundText_meetsBasicQualityBars() throws {
        let kb = try Self.loadCatalog()
        var failures: [String] = []

        for entry in kb.catalog.entries {
            let text = entry.userFacingWorkaround

            // Length: too short usually means generic, too long means we
            // lost the user. 25–400 chars is the band hand-curated entries
            // should fit.
            if text.count < 25 {
                failures.append("\(entry.id): workaround too short (\(text.count) chars) — likely generic")
            }
            if text.count > 400 {
                failures.append("\(entry.id): workaround too long (\(text.count) chars) — user won't read")
            }

            // No jargon test — drop in any internal-only language and fail.
            let bannedTokens = ["LCP", "DRM", "Adobe", "RMSDK", "OPDS", "SAML", "OAuth", "OIDC", "stack trace"]
            for token in bannedTokens {
                if text.range(of: token, options: .caseInsensitive) != nil {
                    failures.append("\(entry.id): workaround contains internal jargon '\(token)' — rewrite for patrons")
                }
            }

            // Fixed-in entries should mention "next release" or a version
            // so the user knows there's a forward path.
            if entry.status == .fixedIn {
                let mentionsRelease = text.range(of: "release", options: .caseInsensitive) != nil
                    || text.range(of: "update", options: .caseInsensitive) != nil
                    || (entry.fixedInVersion != nil && text.contains(entry.fixedInVersion!))
                if !mentionsRelease {
                    failures.append("\(entry.id): status=fixed_in but workaround doesn't mention release / update / version")
                }
            }

            // No empty workaround — should never ship.
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                failures.append("\(entry.id): workaround is empty")
            }
        }

        if !failures.isEmpty {
            for f in failures { print("  QUALITY: \(f)") }
        }
        XCTAssertTrue(failures.isEmpty, "Workaround quality bar failures (\(failures.count)). See test output.")
    }

    // MARK: - Helpers

    private static func loadCatalog() throws -> KnowledgeBase {
        let source = BundledCatalogSource()
        var caught: Error?
        var catalog: KBCatalog!
        let group = DispatchGroup()
        group.enter()
        Task {
            do { catalog = try await source.loadCatalog() } catch { caught = error }
            group.leave()
        }
        group.wait()
        if let e = caught { throw e }
        return KnowledgeBase(catalog: catalog)
    }
}
