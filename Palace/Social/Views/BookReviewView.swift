//
//  BookReviewView.swift
//  Palace
//
//  Created for Social Features — star rating and text review editor.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Sheet for creating or editing a book review with star rating.
struct BookReviewView: View {
    @StateObject private var viewModel: BookReviewViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: BookReviewViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Rating") {
                    StarRatingView(rating: $viewModel.rating)
                        .padding(.vertical, 8)
                }

                Section("Review") {
                    TextEditor(text: $viewModel.reviewText)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Review text")
                }

                Section {
                    Button("Save Review") {
                        viewModel.saveReview()
                        dismiss()
                    }
                    .disabled(!viewModel.canSave)
                    .accessibilityLabel("Save Review")

                    if viewModel.existingReview != nil {
                        Button("Delete Review", role: .destructive) {
                            viewModel.deleteReview()
                            dismiss()
                        }
                        .accessibilityLabel("Delete Review")
                    }
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Star Rating View

/// Interactive 5-star rating view with tap and drag support.
struct StarRatingView: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.title)
                    .foregroundColor(star <= rating ? .orange : .gray)
                    .onTapGesture {
                        rating = star
                    }
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                    .accessibilityAddTraits(star == rating ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rating) out of 5 stars")
        .accessibilityValue("\(rating) stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                if rating < 5 { rating += 1 }
            case .decrement:
                if rating > 1 { rating -= 1 }
            @unknown default:
                break
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let starWidth: CGFloat = 40 // approximate star + spacing
                    let newRating = max(1, min(5, Int(value.location.x / starWidth) + 1))
                    rating = newRating
                }
        )
    }
}
