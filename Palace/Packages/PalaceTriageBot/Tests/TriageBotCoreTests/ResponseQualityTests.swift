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

    // Targets for the real (non-demo) v1.2 corpus. Raised off the demo
    // calibration once the matcher was corrected (smart-punctuation +
    // distinct-region counting) and coverage grew (add-library KI + how_to
    // lane). Precision/rejection are raised because a wrong or misdirected
    // answer is the expensive failure; recall is deliberately HELD at 0.75 —
    // the how_to lane is young and grows in PP-4831, and raising recall while
    // still curating keywords is self-defeating (a miss escalates safely to a
    // human; a false match misleads).
    static let recallTarget: Double = 0.75       // bot finds ≥75% of in-KB issues
    static let precisionTarget: Double = 0.95    // when bot DOES match, it's right ≥95% of the time
    static let rejectionTarget: Double = 0.90    // bot correctly escalates ≥90% of novel issues

    // How_to is a small slice of positives (n=5); it can regress to escalate
    // while global recall stays above target. Guard it with its own floor.
    static let howToRecallTarget: Double = 0.80

    // A wrong how_to answer is an authoritative-sounding falsehood about the
    // product — worse than escalating. how_to precision must be perfect: every
    // how_to the bot surfaces must be the RIGHT how_to.
    static let howToPrecisionTarget: Double = 1.0

    // The REAL ratchet. The soft aggregate targets above have a wide dead zone
    // (the suite scores ~100% today but targets are 75–95%), so a regression can
    // hide. These allowlists pin the EXACT set of cases allowed to miss / be
    // misclassified — keyed by userText. All empty today: any newly-missed case
    // fails by name. To deliberately accept a regression, add its userText here
    // with a comment explaining why (that review is the point).
    static let acceptedRecallMisses: Set<String> = []
    static let acceptedFalseSuggests: Set<String> = []
    static let acceptedRejectionFailures: Set<String> = []

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
             expect: .shouldMatch(entryId: "KI-2026-009-add-library-stale-registry"),
             source: "HelpSpot 17930 — stale Add Library registry cache; fix was pull-to-refresh. Now covered by KI-009"),

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

        // === Smart punctuation — real iOS keyboard input (U+2019) ===
        // The same phrasing as the KI-001 cases above, but with the curly
        // apostrophe a stock iPhone actually types. Before normalization this
        // matched nothing; it must now recall exactly like the ASCII form.
        Case(userText: "my audiobook won\u{2019}t play the first time, it just spins",
             category: .audiobook, context: marketplaceContext,
             expect: .shouldMatch(entryId: "KI-2026-001-audiobook-first-open-hang"),
             source: "real-keyboard variant of HelpSpot 17964 (curly apostrophe)"),

        // === KI-2026-009 add-a-library stale registry ===
        Case(userText: "I can't add a second library, the search doesn't show it",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "KI-2026-009-add-library-stale-registry"),
             source: "paraphrase of HelpSpot 17930 — add-second-library, stale registry"),

        // === HT-2026-001 renewals (how_to) ===
        Case(userText: "how many times can I renew my loan",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-001-renewals"),
             source: "HelpSpot 18028 — renewal limits question; answer: Palace has no in-app renewal"),

        Case(userText: "can I extend my loan to keep the book longer",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-001-renewals"),
             source: "HelpSpot 18187 — 'make renewing easier'; same underlying answer"),

        // === HT-2026-002 return early (how_to) ===
        Case(userText: "how do I return a book early before it's due",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-002-return-early"),
             source: "HelpSpot 17901 — returning a title before the due date"),

        // === HT-2026-003 switch library (how_to) ===
        Case(userText: "how do I switch between libraries",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-003-switch-library"),
             source: "common patron question — multiple libraries in one app"),

        // === HT-2026-004 notifications / reminders (how_to) ===
        Case(userText: "how do I get notified when my hold is ready",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-004-notifications"),
             source: "HelpSpot 18103 — hold-ready + due-soon reminders; enable notifications"),

        // === HT-2026-005 hold pick-up window (how_to) ===
        Case(userText: "how long do I have to pick up my hold once it's ready",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-005-hold-pickup-window"),
             source: "PP-4831 FAQ (David Wilcox, option b) — pickup window varies by library/distributor; 'pick up by' date shown on the hold"),

        Case(userText: "when do I lose my hold if I don't grab it",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-005-hold-pickup-window"),
             source: "PP-4831 FAQ — hold expiry / pickup deadline"),

        // === HT-2026-006 borrow limit (how_to) ===
        Case(userText: "how many books can I borrow at once",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-006-borrow-limit"),
             source: "PP-4831 FAQ (David Wilcox, option b) — per-library borrow limit; generic answer + free a slot by returning"),

        Case(userText: "what is my checkout limit",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-006-borrow-limit"),
             source: "PP-4831 FAQ — loan/checkout limit is set per-library"),

        // === HT-2026-007 loan length (how_to) ===
        Case(userText: "how long is a loan and when is it due",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-007-loan-length"),
             source: "PP-4831 FAQ (David Wilcox, option b) — loan length varies by library; due date shown on each title"),

        Case(userText: "how long is the lending period for a book",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-007-loan-length"),
             source: "PP-4831 FAQ — lending period is per-library"),

        // === HT-2026-008 add library card (how_to) ===
        Case(userText: "how do I add my library card",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-008-add-library-card"),
             source: "PP-4831 FAQ — adding a card: Settings → Libraries → add + sign in with barcode/PIN"),

        Case(userText: "where do I enter my barcode to sign in",
             category: .library, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-008-add-library-card"),
             source: "PP-4831 FAQ — where to enter the library card number"),

        // === HT-2026-009 formats / send-to-Kindle (how_to) ===
        Case(userText: "how do I send my book to Kindle",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-009-formats-kindle"),
             source: "PP-4831 FAQ (product-confirmed not supported) — Palace isn't connected to Kindle; you read in-app"),

        Case(userText: "what formats can I read in the app",
             category: .other, context: nil,
             expect: .shouldMatch(entryId: "HT-2026-009-formats-kindle"),
             source: "PP-4831 FAQ — reading formats are read in-app, no Kindle export"),

        // how_to negative — no FAQ answer exists; must still escalate, not
        // grab a loosely-related how_to.
        Case(userText: "how do I delete my account permanently",
             category: .other, context: nil,
             expect: .shouldEscalate,
             source: "no how_to for account deletion — routes to a human"),

        // === how_to ADVERSARIAL near-misses (token-bearing, wrong intent) ===
        // These share a bare word with a how_to entry but are NOT that question.
        // They must escalate — proof the how_to keywords are specific multi-word
        // intent phrases, not single words. (The renew-card one was a live false
        // positive under the earlier bare "renew" keyword.)
        Case(userText: "the library renewed my card and now Palace won't accept my new barcode",
             category: nil, context: nil,
             expect: .shouldEscalate,
             source: "adversarial — card renewal, NOT loan renewal; must not hit HT-001"),

        Case(userText: "I returned the book last week but it still shows on my shelf",
             category: nil, context: nil,
             expect: .shouldEscalate,
             source: "adversarial — a return BUG (past tense), not 'how do I return'; must not hit HT-002"),

        Case(userText: "the app switched my library on its own and lost my place",
             category: nil, context: nil,
             expect: .shouldEscalate,
             source: "adversarial — an unwanted auto-switch, not 'how do I switch'; must not hit HT-003"),
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
            XCTAssertLessThanOrEqual(result.confidence, 1.0,
                                     "confidence must never exceed 1.0 (score cap): '\(c.userText)'")
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
        // Exact ratchet: the set of missed cases must equal the accepted set.
        XCTAssertEqual(
            Set(misses.map { $0.0.userText }), Self.acceptedRecallMisses,
            "Recall miss SET changed. A case newly regressed to non-suggest (or an accepted miss was fixed — remove it from acceptedRecallMisses)."
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
        XCTAssertEqual(
            Set(falseSuggests.map { $0.0.userText }), Self.acceptedFalseSuggests,
            "False-suggest SET changed. The bot newly misdirected a case (a wrong or should-escalate case now suggests)."
        )
    }

    // MARK: - Negative rejection (novel issues correctly escalate)

    func testRejection_meetsTarget() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()

        let negativeCases = Self.corpus.filter { $0.expect == .shouldEscalate }

        var rejected = 0
        var disambiguated: [(Case, ClassificationResult)] = []
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
                // NOT counted as a rejection. A disambiguation on a novel issue
                // is not a false suggestion, but as the corpus grows two stray
                // keywords increasingly trip a 2-way disambiguation between
                // irrelevant cards — counting that as "rejected" would let the
                // metric ratchet nothing. Reported separately so we can see it.
                disambiguated.append((c, result))
            } else {
                falseSuggests.append((c, result))
            }
        }

        let rejection = Double(rejected) / Double(negativeCases.count)
        if !falseSuggests.isEmpty || !disambiguated.isEmpty {
            print("[rejection] \(rejected)/\(negativeCases.count) = \(String(format: "%.0f%%", rejection * 100)) (escalate only; \(disambiguated.count) disambiguated, not counted)")
            for (c, r) in falseSuggests {
                print("  OVER-MATCH: '\(c.userText)' (\(c.source)) → \(r.decision)")
            }
            for (c, r) in disambiguated {
                print("  DISAMBIGUATED (not counted as rejection): '\(c.userText)' → \(r.decision)")
            }
        }
        XCTAssertGreaterThanOrEqual(
            rejection, Self.rejectionTarget,
            "Rejection \(rejection) below target \(Self.rejectionTarget). Novel issues being misdirected to a KB workaround."
        )
        // A negative case that SUGGESTS is a real misdirection (disambiguate is
        // tracked separately above). Pin the exact set.
        XCTAssertEqual(
            Set(falseSuggests.map { $0.0.userText }), Self.acceptedRejectionFailures,
            "Rejection failure SET changed — a novel/adversarial input newly grabbed a KB entry instead of escalating."
        )
    }

    // MARK: - Per-kind recall (how_to must not hide in the aggregate)

    func testRecall_perKind_meetsFloors() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()

        func recall(forHowTo howTo: Bool) -> (hits: Int, total: Int) {
            let cases = Self.corpus.filter {
                if case .shouldMatch(let id) = $0.expect { return id.hasPrefix("HT-") == howTo }
                return false
            }
            var hits = 0
            for c in cases {
                let r = classifier.classify(userText: c.userText, category: c.category, context: c.context, knowledgeBase: kb)
                if case .shouldMatch(let expected) = c.expect, case .suggest(let actual) = r.decision, expected == actual { hits += 1 }
            }
            return (hits, cases.count)
        }

        let howTo = recall(forHowTo: true)
        let known = recall(forHowTo: false)
        XCTAssertGreaterThan(howTo.total, 0, "expected how_to positive cases in the corpus")
        XCTAssertGreaterThanOrEqual(
            Double(howTo.hits) / Double(howTo.total), Self.howToRecallTarget,
            "how_to recall \(howTo.hits)/\(howTo.total) below \(Self.howToRecallTarget) — FAQ answers regressing to escalate, hidden by the aggregate."
        )
        XCTAssertGreaterThanOrEqual(
            Double(known.hits) / Double(known.total), Self.recallTarget,
            "known_issue recall \(known.hits)/\(known.total) below \(Self.recallTarget)."
        )
    }

    // MARK: - Per-kind precision (a wrong how_to is the worst failure)

    func testPrecision_perKind_meetsFloors() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()

        func precision(forHowTo howTo: Bool) -> (correct: Int, suggested: Int) {
            var correct = 0, suggested = 0
            for c in Self.corpus {
                let r = classifier.classify(userText: c.userText, category: c.category, context: c.context, knowledgeBase: kb)
                guard case .suggest(let id) = r.decision, id.hasPrefix("HT-") == howTo else { continue }
                suggested += 1
                if case .shouldMatch(let expected) = c.expect, expected == id { correct += 1 }
            }
            return (correct, suggested)
        }

        let howTo = precision(forHowTo: true)
        let known = precision(forHowTo: false)
        XCTAssertGreaterThan(howTo.suggested, 0, "expected the bot to surface some how_to answers")
        XCTAssertGreaterThanOrEqual(
            Double(howTo.correct) / Double(howTo.suggested), Self.howToPrecisionTarget,
            "how_to precision \(howTo.correct)/\(howTo.suggested) below \(Self.howToPrecisionTarget) — a wrong FAQ answer is worse than escalating."
        )
        XCTAssertGreaterThanOrEqual(
            Double(known.correct) / Double(known.suggested), Self.precisionTarget,
            "known_issue precision \(known.correct)/\(known.suggested) below \(Self.precisionTarget)."
        )
    }

    // MARK: - Version gate (current-build cohort)

    /// The rest of the corpus runs at appVersion 3.0.3 / nil, so the gate that
    /// hides `fixed_in` entries from patrons who already have the fix was never
    /// exercised. These pin both directions on a current (3.3.0) build.
    func testFixedInEntry_suppressedForPatronWhoHasTheFix() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()
        let current = ContextSnapshot(
            appVersion: "3.3.0", appBuild: "488", osVersion: "26.4.2",
            deviceModel: "iPhone17,2", distributor: "palace_marketplace"
        )

        // KI-007 is fixed_in 3.2.0 — a 3.3.0 patron has the fix, so the same PDF
        // symptom must NOT surface that "update available" card; it escalates as
        // a possible regression instead.
        let result = classifier.classify(
            userText: "PDF won't open, just shows a blank screen",
            category: .reader, context: current, knowledgeBase: kb
        )
        if case .suggest(let id) = result.decision, id == "KI-2026-007-lcp-pdf-fail-to-open" {
            XCTFail("A patron on 3.3.0 already has the 3.2.0 fix — KI-007 must not be suggested")
        }
    }

    func testOpenAndHowToEntries_stillSurfaceOnCurrentBuild() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()
        let current = ContextSnapshot(
            appVersion: "3.3.0", appBuild: "488", osVersion: "26.4.2",
            deviceModel: "iPhone17,2", distributor: "palace_marketplace"
        )

        // A how_to answer has no fix version and must always surface.
        let howTo = classifier.classify(
            userText: "how do I switch between libraries",
            category: .library, context: current, knowledgeBase: kb
        )
        guard case .suggest(let id) = howTo.decision, id == "HT-2026-003-switch-library" else {
            return XCTFail("how_to must surface on a current build; got \(howTo.decision)")
        }
    }

    // MARK: - Coverage: every entry is exercised by the benchmark

    func testEveryCatalogEntry_hasABenchmarkCase() throws {
        let kb = try Self.loadCatalog()
        let entryIds = Set(kb.catalog.entries.map { $0.id })
        let covered = Set(Self.corpus.compactMap { c -> String? in
            if case .shouldMatch(let id) = c.expect { return id }; return nil
        })
        let uncovered = entryIds.subtracting(covered)
        XCTAssertTrue(uncovered.isEmpty,
                      "Catalog entries with NO benchmark shouldMatch case: \(uncovered.sorted()). Every shipped entry must be exercised — add a case when you add an entry.")
    }

    // MARK: - Consistency: paraphrases of one intent land on one entry

    func testParaphraseConsistency_sameIntentSameEntry() throws {
        let classifier = LocalClassifier()
        let kb = try Self.loadCatalog()

        // Distinct phrasings a patron might type for the same need. Not in the
        // main corpus — these specifically test that varied wording is stable.
        let intents: [(entryId: String, category: KBCategory, phrasings: [String])] = [
            ("HT-2026-001-renewals", .other, [
                "how do I renew my loan", "can I renew this book", "is there a way to extend my loan"]),
            ("HT-2026-002-return-early", .other, [
                "how do I return a book early", "how do I return this before it's due"]),
            ("HT-2026-003-switch-library", .library, [
                "how do I switch libraries", "how do I change libraries"]),
        ]

        for intent in intents {
            for phrasing in intent.phrasings {
                let r = classifier.classify(userText: phrasing, category: intent.category, knowledgeBase: kb)
                XCTAssertEqual(r.decision, .suggest(entryId: intent.entryId),
                               "Paraphrase '\(phrasing)' should consistently resolve to \(intent.entryId), got \(r.decision)")
            }
        }
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
        // Use the synchronous loader directly — same fix as the production
        // factory after chaos-qa F-004 flagged the semaphore-bridge pattern.
        let catalog = try BundledCatalogSource.loadCatalogSync()
        return KnowledgeBase(catalog: catalog)
    }
}
