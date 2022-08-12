//
//  EpubPreviewResponseModel.swift
//  Palace
//
//  Created by Maurice Carrier on 8/10/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

class EpubPreviewResponseModel: Codable {
    var epubData: Data
    
    init(data: Data) {
        self.epubData = data
    }
}
