import Foundation

/// A remedy a patron may already have tried before contacting support.
///
/// Measured on 318 real tickets, 10% say up front what they have already done —
/// "They've reinstalled the app, rebooted their phone", "I have uninstalled and
/// redownloaded several times", "tried everything". The bot reads none of it and
/// will cheerfully open a guided flow whose first step is the thing they just
/// told us they did twice.
///
/// That is worse than unhelpful. A patron who has spent twenty minutes
/// reinstalling and is then told to reinstall concludes the thing is not
/// listening, and they are right.
public enum Remedy: String, Codable, Sendable, CaseIterable {
    case reinstall
    case restartDevice
    case signOutIn
    case toggleNetwork
    case reopenTitle
    case updateApp
    case otherDevice
    case pullToRefresh
    case switchLibrary
    /// Check the same account in the library's web catalog.
    ///
    /// Not a repair — it is the one action that splits an app-side problem from
    /// an account-side one (expired card, ILS outage, a title the library does
    /// not license), which is roughly a quarter of real tickets and the class no
    /// app-side remedy can ever fix. Corpus-invisible for a precise reason:
    /// support performs this check itself, server-side, so it is prescribed
    /// almost never and performed almost always.
    case verifyOnWeb

    /// What the remedy costs the patron if it does NOT work.
    ///
    /// The claim that a generic remedy is "never wrong, only unhelpful" is false
    /// in this app, and the distinction is what lets a ladder order itself safely:
    ///
    ///  - `free` — costs seconds and nothing else. Safe to offer early, anywhere.
    ///  - `disruptive` — interrupts something or may cost money (metered data,
    ///    a lost playback position).
    ///  - `destructive` — DESTROYS content. Signing out removes that library's
    ///    downloaded books, and a patron who then cannot sign back in (expired
    ///    card, ILS outage — a quarter of real tickets) has gone from "app
    ///    misbehaving, books still readable" to "locked out, books gone".
    ///    Reinstalling deletes every download across every library, and with the
    ///    Adobe activation history (PP-4951) re-fulfilment afterwards is not
    ///    guaranteed. These go last or never, and always skippable.
    public enum CostTier: String, Codable, Sendable {
        case free
        case disruptive
        case destructive
    }

    public var costTier: CostTier {
        switch self {
        case .pullToRefresh, .reopenTitle, .verifyOnWeb: return .free
        // Not free: minutes, possibly hundreds of megabytes on metered data, an
        // Apple ID prompt and a relaunch. The version gate reduces how often it
        // is WASTED, not what it costs when offered.
        case .updateApp: return .disruptive
        case .restartDevice, .toggleNetwork, .otherDevice: return .disruptive
        // Changing which library is selected is two taps and reversible; it
        // destroys nothing, and the rung that uses it is an observation.
        case .switchLibrary: return .free
        case .signOutIn, .reinstall: return .destructive
        }
    }

    /// Patron-facing name, for acknowledging what they have already done.
    public var displayName: String {
        switch self {
        case .reinstall:     return "reinstalling the app"
        case .restartDevice: return "restarting your device"
        case .signOutIn:     return "signing out and back in"
        case .toggleNetwork: return "switching between WiFi and cellular"
        case .reopenTitle:   return "reopening the title"
        case .updateApp:     return "updating the app"
        case .otherDevice:   return "trying another device"
        case .pullToRefresh: return "pulling down to refresh"
        case .switchLibrary: return "switching libraries"
        case .verifyOnWeb:   return "checking the web catalog"
        }
    }
}

/// Finds remedies the patron says they have ALREADY tried.
///
/// Pure and KMP-portable: token matching against phrase lists, the same
/// mechanism the classifier uses, so a Kotlin port behaves identically.
///
/// Deliberately conservative. A false positive here SKIPS a step the patron
/// might not have taken, which costs them the fix; a false negative merely
/// repeats advice, which is the status quo. So the phrases are all explicit
/// past-tense statements of having done the thing, not mentions of the concept —
/// "I reinstalled" counts, "should I reinstall?" does not.
public struct RemedyDetector: Sendable {

    public init() {}

    /// Past-tense phrasings only. Every entry was taken from wording that appears
    /// in the mined ticket corpus.
    private static let phrases: [Remedy: [String]] = [
        .reinstall: [
            "reinstalled", "re installed", "uninstalled and", "deleted the app",
            "deleted and reinstalled", "removed the app and", "redownloaded the app",
            "delete and reinstall it", "uninstalled it", "deleted palace",
            "fresh install", "took the app off",
        ],
        .restartDevice: [
            // Not bare "rebooted": "my phone rebooted itself while playing" is a
            // symptom (a spontaneous restart), not a remedy the patron applied.
            // Third-person forms are NOT optional — a large share of this corpus
            // is librarians writing on a patron's behalf ("they've reinstalled
            // the app, rebooted their phone"), so a first-person-only list drops
            // them.
            "i rebooted", "rebooted my", "rebooted the", "rebooted their",
            "rebooted her", "rebooted his", "they rebooted",
            "restarted my phone", "restarted the phone", "restarted my ipad",
            "restarted my iphone", "restarted my device", "restarted the app",
            "restarted their phone", "restarted her phone", "restarted his phone",
            "turned my phone off", "turned my ipad off", "power cycled",
            "turned it off and on", "powered it off",
        ],
        .signOutIn: [
            // Phrases match CONTIGUOUS token runs, so "signed out and back" never
            // matched "signed out and SIGNED back in" — the way most people write
            // it. The short trailing forms carry the claim on their own.
            "signed back in", "logged back in", "sign back in",
            "signed out and back", "signed out and in", "logged out and back",
            "logged out and in", "signed out then", "logged out then",
        ],
        .toggleNetwork: [
            "on and off wifi", "off and on wifi", "toggled wifi", "turned wifi off",
            "turned off wifi", "switched to cellular", "tried cellular",
            "different wifi", "different network", "another network",
            "airplane mode on and off", "turned airplane mode on",
            "toggled airplane mode", "restarted my router",
        ],
        .reopenTitle: [
            "closed and reopened", "reopened the book", "reopened it", "opened it again",
            "backed out and tried again",
        ],
        .updateApp: [
            // Not bare "up to date": patrons say it of their library CARD and of
            // iOS. Only claims naming the app or an update count.
            "updated the app", "updated palace", "installed the update",
            "already updated", "on the latest version", "running the latest",
            "app is up to date", "palace is up to date", "installed it again",
        ],
        .pullToRefresh: [
            // Not "pull to refresh" — imperative, so it matches a patron ASKING
            // how, and skips the safest rung in the library ladder.
            "pulled down to refresh", "pulled to refresh",
            "swiped down to refresh", "refreshed the list", "refreshed my holds",
            "i refreshed",
        ],
        .switchLibrary: [
            // NOT "switched libraries" / "switched library" / "changed library":
            // those are KI-2026-002's symptom keywords verbatim. A patron writing
            // "I switched libraries and now my books are gone" is naming their
            // trigger, and treating it as a remedy skipped the library ladder's
            // first rung — the one telling them to check which library is
            // selected, which is the likeliest fix for that exact complaint.
            // Only deliberate-attempt phrasings remain.
            "switched to my other", "tried my other library",
            "changed to my other library", "tried a different library",
        ],
        .verifyOnWeb: [
            "tried the web", "on the website", "in the browser", "web catalog",
            "works on the computer", "on my computer", "logged in online",
        ],
        .otherDevice: [
            "tried on my ipad", "tried on my phone", "tried a different device",
            "on different devices", "on another device", "works on my iphone",
            "works on my ipad",
        ],
    ]

    /// A blanket "I tried everything" claim. Treated as evidence of effort but NOT
    /// mapped to specific remedies — skipping every step on a vague claim would
    /// strand the patron with no path at all.
    private static let blanketPhrases = [
        "tried everything", "done everything", "tried it all", "nothing works",
        "nothing has worked", "tried all your suggestions", "no luck with anything",
        "exhausted every", "at my wits end",
    ]

    /// Remedies the text says were already attempted.
    public func alreadyTried(in text: String) -> Set<Remedy> {
        let tokens = TextTokenizer.tokens(TextNormalizer.normalize(text))
        var found: Set<Remedy> = []
        for (remedy, phrases) in Self.phrases {
            for phrase in phrases {
                let needle = TextTokenizer.tokens(TextNormalizer.normalize(phrase))
                if !TextTokenizer.matchRanges(of: needle, in: tokens).isEmpty {
                    found.insert(remedy)
                    break
                }
            }
        }
        return found
    }

    /// Whether the patron claims broad unsuccessful effort without naming steps.
    /// Worth telling support even though it cannot skip anything.
    public func claimsExhaustedEffort(in text: String) -> Bool {
        let tokens = TextTokenizer.tokens(TextNormalizer.normalize(text))
        return Self.blanketPhrases.contains { phrase in
            !TextTokenizer.matchRanges(
                of: TextTokenizer.tokens(TextNormalizer.normalize(phrase)), in: tokens
            ).isEmpty
        }
    }
}
