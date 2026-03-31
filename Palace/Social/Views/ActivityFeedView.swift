//
//  ActivityFeedView.swift
//  Palace
//
//  Created for Social Features — timeline of reading activity.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Vertical timeline of the user's reading activity with filter chips.
struct ActivityFeedView: View {
    @StateObject private var viewModel: ActivityFeedViewModel

    init(viewModel: ActivityFeedViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter chips
                filterChips
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                if viewModel.activities.isEmpty {
                    emptyState
                } else {
                    activityList
                }
            }
            .navigationTitle("Activity")
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "All",
                    isSelected: viewModel.filterType == nil
                ) {
                    viewModel.clearFilter()
                }

                ForEach(ReadingActivity.ActivityType.allCases, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        isSelected: viewModel.filterType == type
                    ) {
                        viewModel.setFilter(type)
                    }
                }
            }
        }
    }

    // MARK: - Activity List

    private var activityList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.groupedActivities, id: \.0) { group, activities in
                    Section {
                        ForEach(activities) { activity in
                            ActivityRow(activity: activity)
                        }
                    } header: {
                        Text(group)
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Activity Yet")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Your reading activity will appear here as you use Palace.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No activity yet. Your reading activity will appear here as you use Palace.")
    }
}

// MARK: - Activity Row

/// A single activity in the timeline with icon and description.
private struct ActivityRow: View {
    let activity: ReadingActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline icon
            Image(systemName: activity.iconName)
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.displayText)
                    .font(.body)

                Text(activity.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.displayText), \(activity.timestamp.formatted())")
    }
}

// MARK: - Filter Chip

/// A tappable filter chip for activity type filtering.
private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - ActivityType Display Name

extension ReadingActivity.ActivityType {
    var displayName: String {
        switch self {
        case .startedReading: return "Started"
        case .finishedBook: return "Finished"
        case .earnedBadge: return "Badges"
        case .addedToCollection: return "Collections"
        case .wroteReview: return "Reviews"
        }
    }
}
