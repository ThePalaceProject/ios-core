//
//  SamplePlayerError.swift
//  Palace
//
//  Created by Maurice Carrier on 8/15/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

enum SamplePlayerError: Error {
  case sampleDownloadFailed(_ error: Error? = nil)
}
