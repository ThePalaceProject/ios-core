//
//  EpubPreviewRequestModel.swift
//  Palace
//
//  Created by Maurice Carrier on 8/10/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

class EpubPreviewRequestModel: RequestModel {
    
    init(path: String) {
      super.init()
      self.path = path
    }

//    override var path: String

    override var method: RequestType {
        RequestType.get
    }
}
