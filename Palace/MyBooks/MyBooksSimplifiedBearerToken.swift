//
//  MyBooksSimplifiedBearerToken.swift
//  Palace
//
//  Created by Maurice Carrier on 6/13/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class MyBooksSimplifiedBearerToken {
    var accessToken: String
    var expiration: Date
    var location: URL
    /// The original CM fulfill URL used to obtain this token.
    /// Required for refreshing the token after expiration.
    var fulfillURL: URL?

    var isExpired: Bool {
        Date() >= expiration
    }

    init(accessToken: String, expiration: Date, location: URL, fulfillURL: URL? = nil) {
        self.accessToken = accessToken
        self.expiration = expiration
        self.location = location
        self.fulfillURL = fulfillURL
    }

    static func simplifiedBearerToken(with dictionary: [String: Any]) -> MyBooksSimplifiedBearerToken? {
        guard let locationString = dictionary["location"] as? String,
              let location = URL(string: locationString),
              let accessToken = dictionary["access_token"] as? String,
              let expirationNumber = dictionary["expires_in"] as? Int ?? dictionary["expiration"] as? Int else {
            return nil
        }

        let expirationSeconds = expirationNumber > 0 ? expirationNumber : Int(Date.distantFuture.timeIntervalSinceNow)
        let expiration = Date(timeIntervalSinceNow: TimeInterval(expirationSeconds))

        return MyBooksSimplifiedBearerToken(accessToken: accessToken, expiration: expiration, location: location)
    }

    /// Fetches a fresh bearer token from the given CM fulfill URL.
    /// - Parameters:
    ///   - fulfillURL: The CM fulfill URL that returns bearer token JSON.
    ///   - completion: Called with the new token on success, or nil on failure.
    static func refreshToken(from fulfillURL: URL, completion: @escaping (MyBooksSimplifiedBearerToken?) -> Void) {
        var request = URLRequest(url: fulfillURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let authToken = TPPUserAccount.sharedAccount().authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = simplifiedBearerToken(with: dictionary)
            else {
                Log.error(#file, "Failed to refresh bearer token from \(fulfillURL): \(error?.localizedDescription ?? "unknown error")")
                completion(nil)
                return
            }

            token.fulfillURL = fulfillURL
            Log.info(#file, "Successfully refreshed bearer token, expires in \(token.expiration.timeIntervalSinceNow)s")
            completion(token)
        }
        task.resume()
    }
}
