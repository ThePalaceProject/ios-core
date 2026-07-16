#if DEBUG
import XCTest
@testable import TriageBotCore

/// PP-4808/PP-4813 — the DEBUG-only failure-injection gateway. On a bare
/// simulator `canSendMail()` is false, so the real gateways fall back to the
/// always-succeeding clipboard gateway and the error+retry card (AC-8/9) is
/// unreachable on-screen. `ForcedFailureTicketGateway` makes submission fail on
/// demand; this pins that (a) it always throws, (b) the thrown error maps to
/// the intended `SubmissionFailure`, and (c) threading that failure through the
/// real reducer lands on the genuine `.error` recovery card carrying the failed
/// draft (transport) or restores the preview (userCancelled) — the exact
/// production paths, not a fake.
final class ForcedFailureTicketGatewayTests: XCTestCase {

    private func makeReducer() -> ConversationReducer {
        // The .ticketSubmissionFailed path never consults the KB, so an empty
        // catalog is sufficient to drive the failure → recovery transition.
        let catalog = KBCatalog(version: "test", updatedAt: "2026-07-16", entries: [])
        return ConversationReducer(knowledgeBase: KnowledgeBase(catalog: catalog))
    }

    private func makeDraft(_ description: String = "won't play") -> TicketDraft {
        TicketDraft(
            userDescription: description,
            category: .audiobook,
            context: ContextSnapshot(appVersion: "3.3.0", appBuild: "500", osVersion: "26", deviceModel: "iPhone17,2")
        )
    }

    // MARK: - Gateway always throws + maps correctly

    func testTransportMode_throwsErrorMappingToTransportFailure() async {
        let gateway = ForcedFailureTicketGateway(mode: .transport)
        do {
            _ = try await gateway.submit(makeDraft())
            XCTFail("Forced-failure gateway must never succeed")
        } catch let error as SubmissionFailureConvertible {
            guard case .transport(let detail) = error.asSubmissionFailure else {
                return XCTFail(".transport mode must map to a .transport SubmissionFailure")
            }
            XCTAssertFalse(detail.isEmpty, "Transport detail must carry something for Copy details")
        } catch {
            XCTFail("Thrown error must be SubmissionFailureConvertible, got \(error)")
        }
    }

    func testUserCancelledMode_throwsErrorMappingToUserCancelled() async {
        let gateway = ForcedFailureTicketGateway(mode: .userCancelled)
        do {
            _ = try await gateway.submit(makeDraft())
            XCTFail("Forced-failure gateway must never succeed")
        } catch let error as SubmissionFailureConvertible {
            XCTAssertEqual(error.asSubmissionFailure, .userCancelled)
        } catch {
            XCTFail("Thrown error must be SubmissionFailureConvertible, got \(error)")
        }
    }

    func testDefaultMode_isTransport() async {
        let gateway = ForcedFailureTicketGateway()
        do {
            _ = try await gateway.submit(makeDraft())
            XCTFail("Forced-failure gateway must never succeed")
        } catch let error as SubmissionFailureConvertible {
            guard case .transport = error.asSubmissionFailure else {
                return XCTFail("Default mode must be .transport")
            }
        } catch {
            XCTFail("Thrown error must be SubmissionFailureConvertible, got \(error)")
        }
    }

    // MARK: - Injected failure lands on the real reducer recovery path

    /// The full injection chain, minus the ViewModel's Task plumbing: gateway
    /// throws → error is mapped via SubmissionFailureConvertible (exactly what
    /// TriageBotViewModel does) → reducer receives `.ticketSubmissionFailed`
    /// from a `.submitting` state and lands on `.error` carrying the draft.
    func testInjectedTransportFailure_landsReducerInErrorCarryingFailedDraft() async {
        let gateway = ForcedFailureTicketGateway(mode: .transport)
        let draft = makeDraft()

        // Gateway throws; map like the ViewModel does.
        var mapped: SubmissionFailure?
        do {
            _ = try await gateway.submit(draft)
            return XCTFail("Gateway must throw")
        } catch {
            mapped = (error as? SubmissionFailureConvertible)?.asSubmissionFailure
                ?? .transport(detail: error.localizedDescription)
        }
        guard let failure = mapped else { return XCTFail("Failure must be mapped") }

        let reducer = makeReducer()
        let submitting = ConversationState(step: .submitting(ticket: draft))
        let (next, _) = reducer.reduce(state: submitting, action: .ticketSubmissionFailed(failure))

        guard case .error(_, let failedDraft) = next.step else {
            return XCTFail("A transport failure must land on .error, got \(next.step)")
        }
        XCTAssertEqual(failedDraft, draft, "The error step must carry the exact failed draft for Retry / Copy details")
        // The error card must be present so the UI can render Retry / Copy / Start over.
        XCTAssertTrue(
            next.messages.contains { if case .errorActions = $0.kind { return true } else { return false } },
            "The reducer must append an errorActions card driving the AC-8/9 affordances"
        )
    }

    /// The `.userCancelled` injection drives the cancel-restores-preview path.
    func testInjectedUserCancelled_restoresPreviewToDrafting() async {
        let gateway = ForcedFailureTicketGateway(mode: .userCancelled)
        let draft = makeDraft()

        var mapped: SubmissionFailure?
        do {
            _ = try await gateway.submit(draft)
            return XCTFail("Gateway must throw")
        } catch {
            mapped = (error as? SubmissionFailureConvertible)?.asSubmissionFailure
        }
        guard let failure = mapped else { return XCTFail("Failure must be mapped") }

        let reducer = makeReducer()
        let submitting = ConversationState(step: .submitting(ticket: draft))
        let (next, _) = reducer.reduce(state: submitting, action: .ticketSubmissionFailed(failure))

        guard case .drafting(let restored) = next.step else {
            return XCTFail("A user cancel must restore the preview to .drafting, got \(next.step)")
        }
        XCTAssertEqual(restored, draft, "Cancel must restore the exact draft preview")
    }
}
#endif
