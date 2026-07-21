import XCTest
@testable import TriageBotCore

/// PP-4822 (chaos F-001): rapid / double taps on a category chip must produce
/// exactly one conversation turn, not several. The chip tap is debounced at the
/// reducer — once the first tap leaves `.awaitingCategory`, further taps are
/// no-ops (the same guarantee the Send button already has).
final class CategoryChipDebounceTests: XCTestCase {

    private func makeReducer() -> ConversationReducer {
        let catalog = KBCatalog(version: "test", updatedAt: "2026-07-21", entries: [])
        return ConversationReducer(knowledgeBase: KnowledgeBase(catalog: catalog))
    }

    private func startedState(_ r: ConversationReducer) -> ConversationState {
        r.reduce(state: ConversationState(), action: .start).0
    }

    func testRapidSameCategoryTaps_produceExactlyOneTurn() {
        let r = makeReducer()
        var state = startedState(r)

        let (afterFirst, _) = r.reduce(state: state, action: .userTappedCategory(.audiobook))
        let countAfterFirst = afterFirst.messages.count
        XCTAssertEqual(afterFirst.step, .awaitingDescription(category: .audiobook))

        // Two more rapid taps on the same chip before the patron types anything.
        let (afterSecond, _) = r.reduce(state: afterFirst, action: .userTappedCategory(.audiobook))
        let (afterThird, effects) = r.reduce(state: afterSecond, action: .userTappedCategory(.audiobook))

        XCTAssertEqual(afterThird.messages.count, countAfterFirst,
                       "rapid taps must not append additional turns")
        XCTAssertEqual(afterThird.step, .awaitingDescription(category: .audiobook),
                       "step must stay on the first chosen category")
        XCTAssertFalse(effects.contains { if case .emitTelemetry(let e) = $0 { return e.name == "triage_category_chosen" }; return false },
                       "a debounced tap must not re-emit the category-chosen telemetry")
    }

    func testDifferentCategoryTapAfterFirst_isIgnored_firstWins() {
        let r = makeReducer()
        let (afterAudiobook, _) = r.reduce(state: startedState(r), action: .userTappedCategory(.audiobook))
        let (afterReader, _) = r.reduce(state: afterAudiobook, action: .userTappedCategory(.reader))

        XCTAssertEqual(afterReader.step, .awaitingDescription(category: .audiobook),
                       "a second chip tap (even a different category) must not switch the flow")
        XCTAssertEqual(afterReader.messages.count, afterAudiobook.messages.count)
    }

    func testCategoryTap_whileAwaitingCategory_stillWorks() {
        // Guard the positive: the FIRST tap from .awaitingCategory must register.
        let r = makeReducer()
        let (state, effects) = r.reduce(state: startedState(r), action: .userTappedCategory(.signin))
        XCTAssertEqual(state.step, .awaitingDescription(category: .signin))
        XCTAssertTrue(effects.contains { if case .emitTelemetry(let e) = $0 { return e.name == "triage_category_chosen" }; return false })
    }
}
