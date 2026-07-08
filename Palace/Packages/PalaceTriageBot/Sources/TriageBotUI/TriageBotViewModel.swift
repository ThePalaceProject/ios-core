#if canImport(UIKit)
import Foundation
import SwiftUI
import TriageBotCore

/// MainActor controller that bridges SwiftUI to the pure ConversationReducer.
/// Holds state, dispatches actions, and runs the reducer's effects
/// (capture context, submit ticket, emit telemetry) against the injected
/// adapters.
///
/// Intentionally NOT modeled on Palace's `Store<State, Action, Environment>`
/// — this package can't import Palace. The shape is similar but local: a
/// reducer + @Published state + an `apply(effect:)` switch.
@MainActor
public final class TriageBotViewModel: ObservableObject {
    @Published public private(set) var state: ConversationState

    /// Exposed so views can resolve an entry id → entry for rendering KB
    /// match cards without holding their own KB copy.
    public var knowledgeBase: KnowledgeBase { reducer.knowledgeBase }

    private let reducer: ConversationReducer
    private let contextProvider: ContextProvider
    private let ticketGateway: TicketGateway
    private let telemetry: TelemetrySink
    private let fallbackClassifier: FallbackClassifier?

    public init(
        reducer: ConversationReducer,
        contextProvider: ContextProvider,
        ticketGateway: TicketGateway,
        telemetry: TelemetrySink,
        fallbackClassifier: FallbackClassifier? = nil,
        initialState: ConversationState = ConversationState()
    ) {
        self.reducer = reducer
        self.contextProvider = contextProvider
        self.ticketGateway = ticketGateway
        self.telemetry = telemetry
        self.fallbackClassifier = fallbackClassifier
        self.state = initialState
    }

    public func send(_ action: ConversationAction) {
        let (next, effects) = reducer.reduce(state: state, action: action)
        state = next
        for effect in effects {
            apply(effect)
        }
    }

    private func apply(_ effect: ConversationEffect) {
        switch effect {
        case .captureContext:
            Task { [contextProvider] in
                let snapshot = await contextProvider.captureSnapshot()
                self.send(.contextLoaded(snapshot))
            }
        case .submitTicket(let draft):
            Task { [ticketGateway] in
                do {
                    let receipt = try await ticketGateway.submit(draft)
                    self.send(.ticketSubmitted(receipt))
                } catch {
                    self.send(.ticketSubmissionFailed(error.localizedDescription))
                }
            }
        case .emitTelemetry(let event):
            telemetry.emit(event)
        case .runAIFallback(let userText, let category, let context):
            Task { [fallbackClassifier, knowledgeBase] in
                guard let fallback = fallbackClassifier else {
                    self.send(.aiFallbackUnavailable)
                    return
                }
                do {
                    let result = try await fallback.classify(
                        userText: userText,
                        category: category,
                        context: context,
                        knowledgeBase: knowledgeBase
                    )
                    self.send(.aiFallbackResolved(result))
                } catch {
                    self.send(.aiFallbackUnavailable)
                }
            }
        }
    }
}
#endif
