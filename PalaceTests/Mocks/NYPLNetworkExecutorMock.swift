//
//  TPPNetworkExecutorMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 2/3/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPRequestExecutorMock: TPPRequestExecuting {
    var requestTimeout: TimeInterval = 60

    // table of all mock response bodies for given URLs
    var responseBodies = [URL: String]()

    /// When set, ALL requests will fail with this HTTP status code.
    var forceFailureStatusCode: Int?

    /// Incremented in `reset()` so that stale GCD blocks from a previous
    /// test skip their completion callback.
    private var generation: Int = 0

    init() {
        // add here the responses of all the api calls whose flow you want to verify
        let userProfileURL = URL(string: "https://circulation.librarysimplified.org/NYNYPL/patrons/me/")!
        responseBodies[userProfileURL] = TPPFake.validUserProfileJson
    }

    /// Call in tearDown to invalidate any pending async completions.
    func reset() {
        generation += 1
    }

    func executeRequest(_ req: URLRequest,
                        enableTokenRefresh: Bool,
                        completion: @escaping (NYPLResult<Data>) -> Void) -> URLSessionDataTask? {

        let capturedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == capturedGeneration else { return }

            guard let url = req.url else {
                completion(.failure(NSError(domain: "Unit tests: empty url",
                                            code: 0, userInfo: nil), nil))
                return
            }

            if let statusCode = self.forceFailureStatusCode {
                let httpResponse = HTTPURLResponse(url: url,
                                                   statusCode: statusCode,
                                                   httpVersion: "1.1",
                                                   headerFields: nil)
                completion(.failure(NSError(domain: "Unit tests: forced \(statusCode)",
                                            code: statusCode, userInfo: nil),
                                    httpResponse))
                return
            }

            guard let responseBody = self.responseBodies[url] else {
                let httpResponse = HTTPURLResponse(url: url,
                                                   statusCode: 404,
                                                   httpVersion: "1.1",
                                                   headerFields: [
                                                    "Date": "Thu, 04 Feb 2021 02:24:08 GMT",
                                                    "Content-Length": "232"])

                completion(.failure(NSError(domain: "Unit tests: 404",
                                            code: 1, userInfo: nil),
                                    httpResponse))
                return
            }

            let responseData = responseBody.data(using: .utf8)!
            let httpResponse = HTTPURLResponse(url: url,
                                               statusCode: 200,
                                               httpVersion: "1.1",
                                               headerFields: [
                                                "Content-Type": "vnd.librarysimplified/user-profile+json",
                                                "Date": "Thu, 04 Feb 2021 02:24:56 GMT",
                                                "Content-Length": "754" ])
            completion(.success(responseData, httpResponse))
        }

        return URLSessionDataTask()
    }
}
