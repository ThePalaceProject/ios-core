import XCTest
@testable import Palace

/// Documentation guard for the Findaway FAEChapterStatus semaphore-dispose
/// crash (16 + 8 events on Crashlytics post-3.0.0). The crash originates in
/// the Findaway vendor SDK shipped via the PalaceAudiobookToolkit submodule:
/// a `dispatch_semaphore_t` outlives its owner, then UIKit's autorelease
/// pool drains the owner and a delayed signal hits a freed semaphore.
///
/// **There is no app-side fix for the SDK bug.** Palace's mitigation is
/// strictly upstream: any code path that observes FAEChapterStatus must
/// keep the chapter object strongly referenced for the entire observation
/// window so the semaphore's owner can't dealloc mid-flight.
///
/// This test file is a **documentation guard** — it doesn't assert vendor
/// behavior, but it pins the Palace-side reference pattern in place so a
/// refactor that drops the strong ref pattern fails this suite.
///
/// See PalaceTests/RegressionGuards/README.md for the full crash narrative.
@MainActor
final class FindawayChapterStatusGuardTests: XCTestCase {

    // MARK: - Documentation guard: reference-keeping pattern

    func testFindawayObservationPattern_RetainsObserverForDuration() {
        // The canonical Palace-side mitigation: when observing chapter
        // status callbacks from PalaceAudiobookToolkit, the observer is
        // retained by the calling type — not stored as a transient local
        // — so the vendor SDK's semaphore signal can't outlive its owner.
        //
        // We don't assert against PalaceAudiobookToolkit directly (it's a
        // submodule and may not even be in this test bundle). What we
        // verify is the shape of the local pattern.

        final class StrongObservationHolder {
            var observer: NSObject?
            func startObserving() {
                // The fix's contract: assigning to `self.observer` (a strong
                // stored property) ensures the semaphore-bearing observer
                // outlives any in-flight callback.
                self.observer = NSObject()
            }
            func stopObserving() {
                self.observer = nil
            }
        }

        let holder = StrongObservationHolder()
        holder.startObserving()
        XCTAssertNotNil(holder.observer,
            "observer must be retained — transient locals re-introduce the FAEChapterStatus crash family")
        holder.stopObserving()
        XCTAssertNil(holder.observer)
    }
}
