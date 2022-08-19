//
//  Sample.swift
//  Palace
//
//  Created by Maurice Carrier on 8/14/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

protocol Sample {
  var url: URL { get }
}

struct AudiobookSample: Sample {
  var url: URL
}

struct EpubSample: Sample {
  var url: URL
}

protocol SampleProvider {
  var sample: Sample { get }
}
