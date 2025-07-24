//
//  NetworkService.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Modern networking service with async/await support
@MainActor
class NetworkService: ObservableObject {
    
    // MARK: - Properties
    
    static let shared = NetworkService()
    
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    
    // MARK: - Published Properties
    
    @Published var isLoading = false
    @Published var networkStatus: NetworkStatus = .unknown
    
    // MARK: - Types
    
    enum NetworkError: LocalizedError {
        case invalidURL
        case noData
        case decodingError(Error)
        case networkError(Error)
        case invalidResponse
        case serverError(Int, String?)
        
        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid URL provided"
            case .noData:
                return "No data received from server"
            case .decodingError(let error):
                return "Failed to decode response: \(error.localizedDescription)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from server"
            case .serverError(let code, let message):
                return "Server error (\(code)): \(message ?? "Unknown error")"
            }
        }
    }
    
    enum NetworkStatus {
        case unknown
        case connected
        case disconnected
        case connecting
    }
    
    // MARK: - Initialization
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.waitsForConnectivity = true
        
        // Enable modern networking optimizations
        if #available(iOS 13.0, *) {
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
        }
        
        self.session = URLSession(configuration: config)
        
        // Setup JSON decoder with proper date decoding
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }
    
    // MARK: - Generic Network Methods
    
    /// Perform a GET request with automatic decoding
    func get<T: Codable>(
        from url: URL,
        responseType: T.Type,
        headers: [String: String] = [:],
        useAuth: Bool = true
    ) async throws -> T {
        let request = try buildRequest(url: url, method: .GET, headers: headers, useAuth: useAuth)
        return try await performRequest(request, responseType: responseType)
    }
    
    /// Perform a POST request with automatic encoding/decoding
    func post<T: Codable, U: Codable>(
        to url: URL,
        body: T,
        responseType: U.Type,
        headers: [String: String] = [:],
        useAuth: Bool = true
    ) async throws -> U {
        var request = try buildRequest(url: url, method: .POST, headers: headers, useAuth: useAuth)
        request.httpBody = try encoder.encode(body)
        return try await performRequest(request, responseType: responseType)
    }
    
    /// Perform a raw data request
    func performDataRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        await setLoading(true)
        defer { Task { @MainActor in self.isLoading = false } }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            // Validate HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                try validateHTTPResponse(httpResponse, data: data)
            }
            
            return (data, response)
        } catch {
            throw NetworkError.networkError(error)
        }
    }
    
    // MARK: - Private Methods
    
    private func buildRequest(
        url: URL,
        method: HTTPMethod,
        headers: [String: String],
        useAuth: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        
        // Add default headers
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        // Add custom headers
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        
        // Add authentication if needed
        if useAuth, let authToken = TPPUserAccount.sharedAccount().authToken {
            request.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        
        // Add user agent
        request.applyCustomUserAgent()
        
        return request
    }
    
    private func performRequest<T: Codable>(
        _ request: URLRequest,
        responseType: T.Type
    ) async throws -> T {
        let (data, _) = try await performDataRequest(request)
        
        guard !data.isEmpty else {
            throw NetworkError.noData
        }
        
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
    }
    
    private func validateHTTPResponse(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            break // Success
        case 400...499:
            let errorMessage = extractErrorMessage(from: data)
            throw NetworkError.serverError(response.statusCode, errorMessage)
        case 500...599:
            let errorMessage = extractErrorMessage(from: data)
            throw NetworkError.serverError(response.statusCode, errorMessage)
        default:
            throw NetworkError.invalidResponse
        }
    }
    
    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Try common error message keys
        let messageKeys = ["message", "error", "detail", "title"]
        for key in messageKeys {
            if let message = json[key] as? String {
                return message
            }
        }
        
        return nil
    }
    
    private func setLoading(_ loading: Bool) {
        isLoading = loading
    }
    
    // MARK: - Supporting Types
    
    enum HTTPMethod: String {
        case GET = "GET"
        case POST = "POST"
        case PUT = "PUT"
        case DELETE = "DELETE"
        case PATCH = "PATCH"
    }
}

// MARK: - Catalog-Specific Extensions

extension NetworkService {
    
    /// Fetch catalog feed with proper error handling
    func fetchCatalogFeed(from url: URL) async throws -> CatalogFeed {
        // First try to get raw XML data
        let request = try buildRequest(url: url, method: .GET, headers: ["Accept": "application/atom+xml"], useAuth: true)
        let (data, response) = try await performDataRequest(request)
        
        // Validate that we received XML
        guard let mimeType = response.mimeType,
              mimeType == "application/atom+xml" else {
            throw NetworkError.invalidResponse
        }
        
        // Parse the OPDS feed
        return try await CatalogFeedParser.parse(data: data)
    }
    
    /// Search catalog with pagination support
    func searchCatalog(
        baseURL: URL,
        query: String,
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> CatalogSearchResult {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "size", value: "\(pageSize)")
        ]
        
        guard let searchURL = components?.url else {
            throw NetworkError.invalidURL
        }
        
        return try await get(from: searchURL, responseType: CatalogSearchResult.self)
    }
}

// MARK: - Reactive Extensions

extension NetworkService {
    
    /// Publisher for network status changes
    var networkStatusPublisher: AnyPublisher<NetworkStatus, Never> {
        $networkStatus.eraseToAnyPublisher()
    }
    
    /// Publisher for loading state changes
    var loadingStatePublisher: AnyPublisher<Bool, Never> {
        $isLoading.eraseToAnyPublisher()
    }
} 