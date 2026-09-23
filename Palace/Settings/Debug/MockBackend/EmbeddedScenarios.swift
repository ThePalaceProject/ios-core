//
//  EmbeddedScenarios.swift
//  Palace
//
//  Pre-built scenarios embedded as Swift string literals.
//  No bundle resource management needed — they compile directly in.
//

#if DEBUG

import Foundation

extension MockScenario {

    static let embeddedScenarios: [MockScenario] = [
        happyPath,
        expiredCredentials,
        loanLimit,
        serverDown,
        slowNetwork,
        holdsReserved,
    ]

    static let happyPath = MockScenario(
        id: "happy_path",
        displayName: "Happy Path",
        description: "All endpoints return successful responses with test library data.",
        routes: [
            MockRoute(pathPattern: ".*/libraries.*", fixtureName: "opds2_feed", statusCode: 200, contentType: "application/opds+json"),
            MockRoute(pathPattern: ".*/authentication_document", fixtureName: "auth_document", statusCode: 200, contentType: "application/vnd.opds.authentication+json"),
            MockRoute(pathPattern: ".*/search.*", fixtureName: "opds2_feed", statusCode: 200, contentType: "application/opds+json"),
            MockRoute(pathPattern: ".*/annotations.*", fixtureName: "annotations", statusCode: 200, contentType: "application/ld+json"),
            MockRoute(pathPattern: ".*/loans($|[/?].*)", fixtureName: "opds2_feed", statusCode: 200, contentType: "application/opds+json"),
            MockRoute(pathPattern: ".*/borrow($|[/?])", fixtureName: "opds2_feed", statusCode: 201, contentType: "application/opds+json"),
            MockRoute(method: "PUT", pathPattern: ".*/revoke", fixtureName: "opds2_feed", statusCode: 200, contentType: "application/opds+json"),
        ]
    )

    static let holdsReserved = MockScenario(
        id: "holds_reserved",
        displayName: "Holds — Reserved + Ready",
        description: "The loans/holds feed returns one reserved hold (queue position 3 of 8, 0/2 copies) plus one ready-to-borrow hold. Populates the Holds tab so its queue-position, ready, and cancel UI can be exercised without waiting on real limited-copy inventory.",
        routes: [
            MockRoute(pathPattern: ".*/authentication_document", fixtureName: "auth_document", statusCode: 200, contentType: "application/vnd.opds.authentication+json"),
            // Loans/holds feed is OPDS 1.x (Atom); the registry sync parses it into `.holding` books.
            MockRoute(pathPattern: ".*/loans($|[/?].*)", fixtureName: "opds1_hold_entries", statusCode: 200, contentType: "application/atom+xml;profile=opds-catalog;kind=acquisition"),
        ]
    )

    static let expiredCredentials = MockScenario(
        id: "expired_credentials",
        displayName: "Expired Credentials",
        description: "Library card has expired. Catalog loads but authenticated requests return 403.",
        routes: [
            MockRoute(pathPattern: ".*/authentication_document", fixtureName: "auth_document", statusCode: 200, contentType: "application/vnd.opds.authentication+json"),
            MockRoute(pathPattern: ".*/loans($|[/?].*)", fixtureName: "problem_documents", fixtureKey: "expired_credentials", statusCode: 403, contentType: "application/problem+json"),
            MockRoute(pathPattern: ".*/borrow($|[/?])", fixtureName: "problem_documents", fixtureKey: "expired_credentials", statusCode: 403, contentType: "application/problem+json"),
            MockRoute(pathPattern: ".*/annotations.*", fixtureName: "problem_documents", fixtureKey: "expired_credentials", statusCode: 403, contentType: "application/problem+json"),
        ]
    )

    static let loanLimit = MockScenario(
        id: "loan_limit",
        displayName: "Loan Limit Reached",
        description: "User has too many active loans. Browsing works but borrowing returns 403.",
        routes: [
            MockRoute(pathPattern: ".*/authentication_document", fixtureName: "auth_document", statusCode: 200, contentType: "application/vnd.opds.authentication+json"),
            MockRoute(pathPattern: ".*/borrow($|[/?])", fixtureName: "problem_documents", fixtureKey: "loan_limit_reached", statusCode: 403, contentType: "application/problem+json"),
        ]
    )

    static let serverDown = MockScenario(
        id: "server_down",
        displayName: "Server Down (502)",
        description: "API endpoints return 502 Bad Gateway. Catalog still loads from real server.",
        routes: [
            MockRoute(pathPattern: ".*/authentication_document", fixtureName: "problem_documents", fixtureKey: "remote_integration_failed", statusCode: 502, contentType: "application/problem+json"),
            MockRoute(pathPattern: ".*/loans($|[/?].*)", fixtureName: "problem_documents", fixtureKey: "remote_integration_failed", statusCode: 502, contentType: "application/problem+json"),
            MockRoute(pathPattern: ".*/borrow($|[/?])", fixtureName: "problem_documents", fixtureKey: "remote_integration_failed", statusCode: 502, contentType: "application/problem+json"),
            MockRoute(pathPattern: ".*/annotations.*", fixtureName: "problem_documents", fixtureKey: "remote_integration_failed", statusCode: 502, contentType: "application/problem+json"),
            MockRoute(pathPattern: ".*/search.*", fixtureName: "problem_documents", fixtureKey: "remote_integration_failed", statusCode: 502, contentType: "application/problem+json"),
        ]
    )

    static let slowNetwork = MockScenario(
        id: "slow_network",
        displayName: "Slow Network (3s delay)",
        description: "Authenticated endpoints respond with a 3-second delay.",
        routes: [
            MockRoute(pathPattern: ".*/authentication_document", fixtureName: "auth_document", statusCode: 200, contentType: "application/vnd.opds.authentication+json", delayMs: 3000),
            MockRoute(pathPattern: ".*/loans($|[/?].*)", fixtureName: "opds2_feed", statusCode: 200, contentType: "application/opds+json", delayMs: 3000),
            MockRoute(pathPattern: ".*/borrow($|[/?])", fixtureName: "opds2_feed", statusCode: 201, contentType: "application/opds+json", delayMs: 3000),
            MockRoute(pathPattern: ".*/annotations.*", fixtureName: "annotations", statusCode: 200, contentType: "application/ld+json", delayMs: 3000),
        ]
    )
}

#endif
