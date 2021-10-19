//
//  NetworkExecutor.swift
//  Palace
//
//  Created by Maurice Carrier on 10/18/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

protocol NetworkExecutor {
  func GET(_ reqURL: URL, completion: @escaping (_ result: NYPLResult<Data>) -> Void)
}
