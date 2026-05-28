//
//  TriageBotSupportView.swift
//  Palace
//
//  SwiftUI host for the triage bot. Wraps the package's SupportChatView in a
//  NavigationStack so it can be pushed from Settings, presented as a sheet
//  from a Help button, or shown full-screen — caller's choice.
//

#if canImport(UIKit)
import SwiftUI
import TriageBotUI

struct TriageBotSupportView: View {
    @StateObject private var viewModel: TriageBotViewModel

    init?() {
        guard let vm = TriageBotFactory.makeViewModel() as? TriageBotViewModel else {
            return nil
        }
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some View {
        SupportChatView(viewModel: viewModel)
    }
}
#endif
