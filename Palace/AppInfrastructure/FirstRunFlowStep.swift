//
//  FirstRunFlowStep.swift
//  Palace
//
//  PP-5220 — the decision behind "does this patron see the library picker?",
//  lifted out of `TPPAppDelegate` so it can be tested.
//
//  ## Why this exists
//
//  That decision could not be reached from a test: it was tangled with app
//  startup, notification observers and a timer, so the one piece of logic in
//  Palace that can leave a brand-new patron with no library — or with four
//  stacked pickers — had no coverage at all. PP-4329 was exactly that bug: an
//  observer that was re-registered and never removed stacked four
//  `TPPAccountList` modals on a fresh install on iOS 26.4.2.
//
//  The MDM work then added a second reason to listen, a deadline timer, and a
//  path that skips the picker entirely. Three more ways for the same decision
//  to go wrong, still with nothing asserting any of it.
//
//  So the decision is a pure function over the five things that actually
//  determine it, and `TPPAppDelegate` is reduced to carrying them in and acting
//  on the answer. The states are finite and enumerable; the scenarios are not.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// What the first-run flow should do, given everything it knows.
enum FirstRunFlowStep: Equatable {
    /// The picker was already presented this launch. PP-4329's guard: the
    /// catalog load posts up to eight notifications in worst-case fallback
    /// paths, and each one re-enters this decision.
    case alreadyHandled

    /// The library list has not loaded, so `currentAccount` would give a false
    /// negative. Wait for it and ask again.
    case waitForCatalog

    /// A managed configuration selected a library. Nobody needs to be asked
    /// anything.
    case librarySelected

    /// A managed configuration is real but not yet actionable. Say nothing and
    /// re-ask when the registry changes — a slow network is not a verdict.
    case waitForManagedLibrary

    /// A library is already selected and nothing needs to change.
    case nothingToDo

    /// Ask the patron to choose a library.
    case presentPicker
}

enum FirstRunFlowDecision {

    /// The whole first-run decision, as one pure function.
    ///
    /// Order matters and is the substance of it:
    ///
    /// 1. `hasPresented` first, because re-entry is the failure that already
    ///    shipped once (PP-4329) and it must short-circuit before anything
    ///    else can present a second picker.
    /// 2. `catalogHasLoaded` next, because every question after it reads state
    ///    that is not trustworthy until the library list exists.
    /// 3. The managed-configuration step, because a configured device should
    ///    never be asked — and because waiting for one must happen before we
    ///    conclude a patron needs the picker.
    /// 4. `hasCurrentAccount` last: only once nothing else has an answer does
    ///    "does this patron already have a library?" decide it.
    static func step(
        hasPresented: Bool,
        catalogHasLoaded: Bool,
        managedStep: ManagedLibraryLaunchStep,
        hasCurrentAccount: Bool
    ) -> FirstRunFlowStep {
        guard !hasPresented else { return .alreadyHandled }
        guard catalogHasLoaded else { return .waitForCatalog }

        switch managedStep {
        case .libraryApplied:
            return .librarySelected
        case .waitForRegistry:
            return .waitForManagedLibrary
        case .presentPicker:
            // The managed path has nothing to say. Fall through to the
            // pre-existing rule, which is the ONLY rule for the overwhelming
            // majority of patrons, who are not managed at all.
            return hasCurrentAccount ? .nothingToDo : .presentPicker
        }
    }
}
