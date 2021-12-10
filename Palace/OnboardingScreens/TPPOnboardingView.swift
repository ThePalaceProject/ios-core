//
//  TPPOnboardingView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 08.12.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPOnboardingView: View {
  
  // 2 x pan distance to switch between slides
  // (relative to screen width)
  private var activationDistance = 0.8
  
  private var onboardingImageNames =
    ["Onboarding-1", "Onboarding-2", "Onboarding-3"]
  @GestureState private var translation: CGFloat = 0
  @Environment(\.presentationMode) var presentationMode
  
  @State private var currentIndex = 0 {
    didSet {
      // Dismiss the view after the user swipes past the last slide.
      if currentIndex == onboardingImageNames.count {
        presentationMode.wrappedValue.dismiss()
      }
    }
  }
  
  var body: some View {
    ZStack(alignment: .top) {
      
      // Onboarding slides
      
      GeometryReader { geometry in
        HStack(spacing: 0) {
          ForEach(onboardingImageNames, id: \.self) { imageName in
            Image(imageName)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: geometry.size.width)
              .edgesIgnoringSafeArea(.bottom)
          }
        }
        .contentShape(Rectangle())
        .frame(width: geometry.size.width, alignment: .leading)
        .offset(x: translation - CGFloat(currentIndex) * geometry.size.width)
        .animation(.interactiveSpring(), value: currentIndex)
        .gesture(
          DragGesture()
            .updating($translation) { value, state, _translation in
              state = value.translation.width
            }
            .onEnded { value in
              let offset = value.translation.width / geometry.size.width / activationDistance
              let newIndex = (CGFloat(currentIndex) - offset).rounded()
              // This is intentional, it makes possible swiping past the last slide to dismiss this view.
              let lastIndex = onboardingImageNames.count
              currentIndex = min(max(Int(newIndex), 0), lastIndex)
            }
        )
      }
      .background(
        Color(UIColor(named: "OnboardingBackground") ?? .systemBackground)
      )
      
      // Pager dots
      
      VStack {
        Spacer()
        TPPPagerDotsView(count: onboardingImageNames.count, currentIndex: $currentIndex)
          .padding()
      }
      
      // Close button
      
      HStack {
        Spacer()
        Button {
          presentationMode.wrappedValue.dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.title)
            .foregroundColor(.gray)
            .padding()
        }
      }
    }
    .statusBar(hidden: true)
  }  
}
