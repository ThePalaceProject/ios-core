//
//  EpubSamplePlayer.swift
//  Palace
//
//  Created by Maurice Carrier on 8/14/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct EpubSamplePlayer: View {
  var sample: EpubSample

  var body: some View {
      contentView
  }

  @ViewBuilder var contentView: some View {
    Text("Show Epub reader")
  }
}

struct EpubSamplePlayer_Previews: PreviewProvider {
  static var previews: some View {
    EpubSamplePlayer(sample: EpubSample(
      url: URL(string:"https://samples.overdrive.com/?crid=08F7D7E6-423F-45A6-9A1E-5AE9122C82E7&amp;.epub-sample.overdrive.com")!
    ))
  }
}
