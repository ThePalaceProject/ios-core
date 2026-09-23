#if canImport(UIKit)
import SwiftUI
import TriageBotCore

/// Top-level chat surface. Host wraps in a NavigationStack and presents
/// however it wants — sheet, pushed view, full-screen. View calls
/// `viewModel.send(.start)` on first appear.
public struct SupportChatView: View {
    @ObservedObject public var viewModel: TriageBotViewModel
    @State private var didStart = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: TriageBotViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .navigationTitle("Get Help")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !didStart {
                didStart = true
                viewModel.send(.start)
            }
        }
    }

    @ViewBuilder private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.state.messages) { message in
                        messageRow(message)
                            .id(message.id)
                            // Each new turn eases in; under Reduce Motion the
                            // row simply appears (`.identity`).
                            .transition(reduceMotion ? .identity : .botEntrance)
                    }
                    if let indicator = gatheringIndicatorLabel {
                        GatheringIndicator(label: indicator)
                            .id(Self.gatheringIndicatorID)
                            .transition(reduceMotion ? .identity : .botEntrance)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                // Drive insertion/removal transitions off the two things that
                // change the log: the message count and whether the working
                // indicator is showing. Gated so Reduce Motion gets no animation.
                .animation(BotUI.Motion.gated(BotUI.Motion.entrance, reduceMotion: reduceMotion),
                           value: viewModel.state.messages.count)
                .animation(BotUI.Motion.gated(BotUI.Motion.entrance, reduceMotion: reduceMotion),
                           value: gatheringIndicatorLabel)
            }
            .onChange(of: viewModel.state.messages.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: gatheringIndicatorLabel) { _, _ in
                scrollToLatest(proxy)
            }
        }
    }

    private static let gatheringIndicatorID = "triagebot.gathering.indicator"

    /// Non-nil while the bot is working and the log would otherwise sit on a
    /// dead pause: the AI classifier is deliberating, or a ticket is in flight.
    private var gatheringIndicatorLabel: String? {
        switch viewModel.state.step {
        case .awaitingAIClassification:
            return "Looking into this…"
        case .submitting:
            return "Sending your ticket…"
        default:
            return nil
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        let animation = BotUI.Motion.gated(BotUI.Motion.scroll, reduceMotion: reduceMotion)
        // When the working indicator is showing it's the bottom-most element,
        // so anchor to it; otherwise anchor to the last message.
        let target: AnyHashable
        if gatheringIndicatorLabel != nil {
            target = Self.gatheringIndicatorID
        } else if let lastID = viewModel.state.messages.last?.id {
            target = lastID
        } else {
            return
        }
        withAnimation(animation) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    @ViewBuilder private func messageRow(_ message: ConversationMessage) -> some View {
        switch message.kind {
        case .text(let text):
            ChatBubble(text: text, sender: message.sender)
        case .categoryChips:
            // PP-4844: chips are only live while the reducer is awaiting a
            // category. Any earlier chip row (e.g. still on-screen after a
            // ticket was sent) is historical — pass isActive: false so it
            // renders dimmed + disabled instead of looking tappable-but-dead.
            CategoryChipsView(isActive: chipsAreLive) { category in
                viewModel.send(.userTappedCategory(category))
            }
        case .kbMatch(let entryId):
            if let entry = entry(for: entryId) {
                KBMatchCard(entry: entry) { action in
                    handleKBAction(action, entryId: entryId)
                }
            }
        case .guidedStep(let entryId, let stepIndex):
            if let entry = entry(for: entryId),
               let steps = entry.userFacingSteps,
               stepIndex < steps.count {
                GuidedStepCard(
                    stepNumber: stepIndex + 1,
                    totalSteps: steps.count,
                    step: steps[stepIndex]
                ) { action in
                    handleGuidedStepAction(action, stepId: steps[stepIndex].id)
                }
            }
        case .ticketPreview(let draft):
            TicketPreviewCard(draft: draft) { action in
                handleTicketPreviewAction(action)
            }
        case .ticketReceipt(let receipt):
            TicketReceiptCard(receipt: receipt)
        case .errorActions(let draft):
            ErrorActionsCard(draft: draft) { action in
                handleErrorAction(action)
            }
        }
    }

    /// Category chips are a live affordance only while the reducer is actually
    /// awaiting a category. In every other step an on-screen chip row is a
    /// historical turn whose taps are reducer no-ops (PP-4844).
    private var chipsAreLive: Bool {
        if case .awaitingCategory = viewModel.state.step { return true }
        return false
    }

    /// The terminal "Sent" state. The ticket is filed and there's no text input
    /// — without an explicit affordance the patron is stranded (PP-4844).
    private var isSentTerminalStep: Bool {
        if case .sent = viewModel.state.step { return true }
        return false
    }

    private struct InputBarConfig {
        let isCompositionStep: Bool
        let isFollowUpStep: Bool
        let placeholder: String
    }

    private var inputBarConfig: InputBarConfig {
        switch viewModel.state.step {
        case .awaitingDescription, .awaitingFollowUp, .awaitingCategory:
            return InputBarConfig(isCompositionStep: true, isFollowUpStep: false, placeholder: "Describe what's happening…")
        case .awaitingEscalationFollowUp:
            return InputBarConfig(isCompositionStep: true, isFollowUpStep: true, placeholder: "Type your answer (or tap Skip)…")
        default:
            return InputBarConfig(isCompositionStep: false, isFollowUpStep: false, placeholder: "Describe what's happening…")
        }
    }

    @ViewBuilder private var inputBar: some View {
        let config = inputBarConfig
        let isFollowUpStep = config.isFollowUpStep
        let placeholder = config.placeholder

        if config.isCompositionStep {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    TextField(
                        placeholder,
                        text: Binding(
                            get: { viewModel.state.inputText },
                            set: { viewModel.send(.inputChanged($0)) }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityLabel(placeholder)

                    Button {
                        if isFollowUpStep {
                            let trimmed = viewModel.state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                            viewModel.send(.userAnsweredEscalationFollowUp(answer: trimmed.isEmpty ? nil : trimmed))
                        } else {
                            viewModel.send(.userSubmittedDescription)
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(!isFollowUpStep && viewModel.state.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(isFollowUpStep ? "Send answer" : "Send")
                }
                if isFollowUpStep {
                    Button {
                        viewModel.send(.userAnsweredEscalationFollowUp(answer: nil))
                    } label: {
                        Label("Skip this question", systemImage: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Skip this follow-up question and file the ticket without an answer")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else if isSentTerminalStep {
            // PP-4844: the ticket is filed and there's no text field, so the
            // only recovery used to be closing + reopening the Help sheet.
            // Give the patron a first-class way to keep going. This dispatches
            // the reducer's existing reset action (.userTappedStartOver), which
            // clears state back to a fresh category prompt.
            BotUI.PrimaryButton(title: "Ask another question", systemImage: "plus.bubble") {
                viewModel.send(.userTappedStartOver)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityHint("Starts a new question. Your sent ticket is unaffected.")
        }
    }

    private func entry(for id: String) -> KBEntry? {
        viewModel.knowledgeBase.entry(id: id)
    }

    private func handleKBAction(_ action: KBMatchCard.Action, entryId: String) {
        switch action {
        case .notifyMe:
            viewModel.send(.userTappedNotifyMeOnFix(entryId: entryId))
        case .fileAnyway:
            viewModel.send(.userTappedFileTicketAnyway)
        case .dismiss:
            viewModel.send(.userTappedDismiss)
        case .walkMeThroughIt:
            viewModel.send(.userTappedStartGuidedFlow(entryId: entryId))
        }
    }

    private func handleGuidedStepAction(_ action: GuidedStepCard.Action, stepId: String) {
        switch action {
        case .selectedResponse(let index):
            viewModel.send(.userSelectedStepResponse(stepId: stepId, responseIndex: index))
        case .resolved:
            viewModel.send(.userConfirmedStepResolved(stepId: stepId))
        case .didNotResolve:
            viewModel.send(.userConfirmedStepDidNotResolve(stepId: stepId))
        case .abandon:
            viewModel.send(.userTappedAbandonGuidedFlow)
        }
    }

    private func handleTicketPreviewAction(_ action: TicketPreviewCard.Action) {
        switch action {
        case .send:
            viewModel.send(.userConfirmedTicketSubmit)
        case .cancel:
            viewModel.send(.userCancelledTicketSubmit)
        case .toggleField(let field):
            viewModel.send(.userToggledDraftField(field))
        case .omitLogs(let omit):
            viewModel.send(.userOmittedLogs(omit))
        case .editDescription(let text):
            viewModel.send(.userEditedDescription(text))
        case .presented:
            viewModel.send(.ticketPreviewPresented)
        }
    }

    private func handleErrorAction(_ action: ErrorActionsCard.Action) {
        switch action {
        case .retry:
            viewModel.send(.userTappedRetrySubmission)
        case .copyDetails(let draft):
            // Let the patron email support themselves with the exact payload.
            let details = TicketEmailComposition.body(for: draft)
            UIPasteboard.general.string = details
        case .startOver:
            viewModel.send(.userTappedStartOver)
        }
    }
}

#endif
