//
//  AccountDetailSkeletonView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

struct AccountDetailSkeletonView: View {
  @State private var pulse = false
  
  var body: some View {
    List {
      headerSkeleton
      
      Section {
        ForEach(0..<3, id: \.self) { _ in
          fieldSkeleton
        }
      }
      
      Section {
        fieldSkeleton
      }
    }
    .listStyle(GroupedListStyle())
    .onAppear {
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
  
  private var headerSkeleton: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(Color.gray.opacity(0.25))
        .frame(width: 50, height: 50)
        .opacity(pulse ? 0.6 : 1.0)
      
      Rectangle()
        .fill(Color.gray.opacity(0.25))
        .frame(width: 150, height: 20)
        .opacity(pulse ? 0.6 : 1.0)
      
      Spacer()
    }
    .padding(.vertical, 8)
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets())
  }
  
  private var fieldSkeleton: some View {
    Rectangle()
      .fill(Color.gray.opacity(0.25))
      .frame(height: 44)
      .opacity(pulse ? 0.6 : 1.0)
  }
}

