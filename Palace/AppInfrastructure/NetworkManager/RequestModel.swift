//
//  RequestModel.swift
//  Palace
//
//  Created by Maurice Carrier on 8/10/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

enum RequestType: String {
    case get = "GET"
    case post = "POST"
}

class RequestModel: NSObject {
    
    var path: String = ""

    var parameters: [String : String] {
        [:]
    }

    var headers: [String: String] {
        [:]
    }
    
    var method: RequestType {
        body.isEmpty ? .get : .post
    }
    
    var body: [String: Any?] {
        [:]
    }
    
    func urlRequest() -> URLRequest {
        var components = URLComponents(string: path)!
        
        components.queryItems = parameters.map { (key, value) in
            URLQueryItem(name: key, value: value)
        }

        var request: URLRequest = URLRequest(url: components.url!)
        request.httpMethod = method.rawValue.uppercased()
        
        for header in headers {
            request.addValue(header.value, forHTTPHeaderField: header.key)
        }
  
        return request
    }
}
