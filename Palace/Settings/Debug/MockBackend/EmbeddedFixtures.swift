//
//  EmbeddedFixtures.swift
//  Palace
//
//  Fixture data embedded as Swift string literals.
//  These are the same JSON files from PalaceTests/Fixtures/API/,
//  compiled directly into the binary so no bundle resources needed.
//

#if DEBUG

import Foundation

enum EmbeddedFixtures {

    static func data(for name: String) -> Data? {
        switch name {
        case "opds2_feed": return opds2Feed.data(using: .utf8)
        case "auth_document": return authDocument.data(using: .utf8)
        case "problem_documents": return problemDocuments.data(using: .utf8)
        case "annotations": return annotations.data(using: .utf8)
        default: return nil
        }
    }

    static let opds2Feed = """
    {"metadata":{"title":"A1QA Test Library","itemsPerPage":50},"links":[{"rel":"self","href":"https://gorgon.staging.palaceproject.io/a1qa-test/","type":"application/opds+json"},{"rel":"search","href":"https://gorgon.staging.palaceproject.io/a1qa-test/search{?query}","type":"application/opds+json","templated":true}],"publications":[{"metadata":{"identifier":"urn:uuid:b309a3a0-1234","title":"Agnes Grey","author":[{"name":"Anne Bront\\u00eb"}],"published":"2020-01-15","language":["en"],"description":"A heroine who is honest, perceptive and charming."},"images":[{"href":"https://example.com/cover.jpg","type":"image/jpeg"}],"links":[{"rel":"http://opds-spec.org/acquisition/borrow","href":"https://gorgon.staging.palaceproject.io/a1qa-test/works/b309a3a0/borrow","type":"application/atom+xml;type=entry;profile=opds-catalog","properties":{"availability":{"state":"available"},"copies":{"total":9999,"available":9999}}}]},{"metadata":{"identifier":"urn:uuid:audio-1234","type":"http://schema.org/Audiobook","title":"Animal Farm","author":[{"name":"George Orwell"}],"published":"2019-06-01","language":["en"],"duration":10800},"images":[{"href":"https://example.com/animal-farm.jpg","type":"image/jpeg"}],"links":[{"rel":"http://opds-spec.org/acquisition/borrow","href":"https://gorgon.staging.palaceproject.io/a1qa-test/works/audio-1234/borrow","type":"application/atom+xml;type=entry;profile=opds-catalog","properties":{"availability":{"state":"available"},"copies":{"total":5,"available":3}}}]}],"groups":[{"metadata":{"title":"Unlimited Listens ODL Feed"},"links":[{"rel":"self","href":"https://gorgon.staging.palaceproject.io/a1qa-test/groups/unlimited-listens","type":"application/opds+json"}],"publications":[]}],"facets":[{"metadata":{"title":"Format"},"links":[{"rel":"http://opds-spec.org/facet","href":"https://gorgon.staging.palaceproject.io/a1qa-test/?entrypoint=All","title":"All","properties":{"activeFacet":true}},{"rel":"http://opds-spec.org/facet","href":"https://gorgon.staging.palaceproject.io/a1qa-test/?entrypoint=eBooks","title":"eBooks"},{"rel":"http://opds-spec.org/facet","href":"https://gorgon.staging.palaceproject.io/a1qa-test/?entrypoint=Audiobooks","title":"Audiobooks"}]}]}
    """

    static let authDocument = """
    {"title":"A1QA Test Library","service_description":"A test library for QA.","id":"https://gorgon.staging.palaceproject.io/a1qa-test/authentication_document","authentication":[{"type":"http://palaceproject.io/authtype/Basic","description":"Library Card","labels":{"login":"Barcode","password":"PIN"},"inputs":{"login":{"keyboard":"DEFAULT","maximum_length":14},"password":{"keyboard":"NUMBER_PAD"}}}],"links":[{"rel":"start","href":"https://gorgon.staging.palaceproject.io/a1qa-test/","type":"application/atom+xml;profile=opds-catalog"},{"rel":"help","href":"mailto:support@example.com"},{"rel":"terms-of-service","href":"https://thepalaceproject.org/terms/"},{"rel":"privacy-policy","href":"https://thepalaceproject.org/privacy/"}],"features":{"enabled":["reservations"],"disabled":[]},"announcements":[]}
    """

    static let problemDocuments = """
    {"invalid_credentials":{"type":"http://librarysimplified.org/terms/problem/invalid-credentials","status":401,"title":"Invalid Credentials","detail":"A valid library card barcode number and PIN are required."},"expired_credentials":{"type":"http://librarysimplified.org/terms/problem/expired-credentials","status":403,"title":"Expired Credentials","detail":"Library card has expired."},"loan_limit_reached":{"type":"http://librarysimplified.org/terms/problem/loan-limit-reached","status":403,"title":"Loan Limit Reached","detail":"You have reached your loan limit. Please return books before borrowing more."},"hold_limit_reached":{"type":"http://librarysimplified.org/terms/problem/hold-limit-reached","status":403,"title":"Hold Limit Reached","detail":"You have reached your hold limit."},"no_licenses":{"type":"http://librarysimplified.org/terms/problem/no-licenses","status":404,"title":"No Licenses","detail":"The library currently has no licenses for this book."},"no_available_license":{"type":"http://librarysimplified.org/terms/problem/no-available-license","status":403,"title":"No Available License","detail":"All licenses for this book are loaned out."},"already_checked_out":{"type":"http://librarysimplified.org/terms/problem/already-checked-out","status":400,"title":"Already Checked Out","detail":"You have already checked out this book."},"remote_integration_failed":{"type":"http://librarysimplified.org/terms/problem/remote-integration-failed","status":502,"title":"Remote Integration Failed","detail":"A third-party service has failed."}}
    """

    static let annotations = """
    {"@context":"http://www.w3.org/ns/anno.jsonld","id":"https://example.com/annotations/","type":["BasicContainer","AnnotationCollection"],"total":2,"first":{"id":"https://example.com/annotations/page/1","type":"AnnotationPage","items":[{"id":"https://example.com/annotations/abc123","type":"Annotation","motivation":"http://www.w3.org/ns/oa#idling","body":{"http://librarysimplified.org/terms/time":"2026-04-10T14:30:00Z","http://librarysimplified.org/terms/device":"urn:uuid:device-1234","http://librarysimplified.org/terms/chapter":"Chapter 3"},"target":{"source":"urn:uuid:b309a3a0-1234","selector":{"type":"oa:FragmentSelector","value":"{\\"idref\\":\\"chapter3\\",\\"contentCFI\\":\\"/4/2/10\\",\\"progressWithinChapter\\":0.45,\\"progressWithinBook\\":0.23}"}}},{"id":"https://example.com/annotations/def456","type":"Annotation","motivation":"http://www.w3.org/ns/oa#bookmarking","body":{"http://librarysimplified.org/terms/time":"2026-04-09T08:15:00Z"},"target":{"source":"urn:uuid:b309a3a0-1234","selector":{"type":"oa:FragmentSelector","value":"{\\"idref\\":\\"chapter1\\",\\"contentCFI\\":\\"/4/2/4\\",\\"progressWithinChapter\\":0.10,\\"progressWithinBook\\":0.05}"}}}]}}
    """
}

#endif
