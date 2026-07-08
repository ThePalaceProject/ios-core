#if canImport(UIKit)
import SwiftUI
import TriageBotCore

/// Top-level chat surface. Host wraps in a NavigationStack and presents
/// however it wants — sheet, pushed view, full-screen. View calls
/// `viewModel.send(.start)` on first appear.
public struct SupportChatView: View {
    @ObservedObject public var viewModel: TriageBotViewModel
    @State private var didStart = false

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
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.state.messages.count) { _ in
                guard let last = viewModel.state.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder private func messageRow(_ message: ConversationMessage) -> some View {
        switch message.kind {
        case .text(let text):
            ChatBubble(text: text, sender: message.sender)
        case .categoryChips:
            CategoryChipsView { category in
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
        }
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
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Skip this follow-up question and file the ticket without an answer")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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
        }
    }
}

#endif
