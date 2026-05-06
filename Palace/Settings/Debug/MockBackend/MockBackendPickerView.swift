//
//  MockBackendPickerView.swift
//  Palace
//
//  Debug menu UI for activating/deactivating the mock backend
//  and selecting test scenarios.
//

#if DEBUG

import SwiftUI

struct MockBackendPickerView: View {
    @ObservedObject var service = MockBackendService.shared

    var body: some View {
        List {
            Section {
                Toggle("Mock Backend", isOn: Binding(
                    get: { service.isActive },
                    set: { newValue in
                        if newValue {
                            if let first = service.availableScenarios.first {
                                service.activate(scenario: first)
                            }
                        } else {
                            service.deactivate()
                        }
                    }
                ))

                if service.isActive, let current = service.currentScenario {
                    HStack {
                        Text("Active Scenario")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(current.displayName)
                            .foregroundColor(.primary)
                    }
                }
            } header: {
                Text("Mock Backend")
            } footer: {
                Text("When enabled, ALL network requests are intercepted and served from local fixture files. No real server traffic.")
            }

            if service.isActive {
                Section("Scenarios") {
                    ForEach(service.availableScenarios) { scenario in
                        Button {
                            service.activate(scenario: scenario)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(scenario.displayName)
                                        .foregroundColor(.primary)
                                    Text(scenario.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                if service.currentScenario?.id == scenario.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                Section("Diagnostics") {
                    HStack {
                        Text("Routes")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(service.currentScenario?.routes.count ?? 0)")
                    }

                    HStack {
                        Text("Fixture Bundle")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(MockBackendURLProtocol.fixtureBundle == .main ? "Main" : "Test")
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Mock Backend")
    }
}

#endif
