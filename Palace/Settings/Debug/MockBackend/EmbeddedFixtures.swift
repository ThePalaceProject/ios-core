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
        case "opds1_hold_entries": return holdsFeed.data(using: .utf8)
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

    /// OPDS 1.x (Atom) loans/holds feed — one reserved hold (queue position 3
    /// of 8, 0 of 2 copies) + one ready-to-borrow hold. Mirrors
    /// PalaceTests/Fixtures/API/opds1_hold_entries.xml so the app can populate
    /// the Holds tab from the mock backend (the test bundle can't be read at
    /// app runtime). Served by the `holds_reserved` scenario for the /loans
    /// route; the registry sync parses it into `.holding` books.
    static let holdsFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"
          xmlns:opds="http://opds-spec.org/2010/catalog"
          xmlns:schema="http://schema.org/"
          xmlns:dcterms="http://purl.org/dc/terms/"
          xmlns:bibframe="http://bibframe.org/vocab/"
          xmlns:simplified="http://librarysimplified.org/terms/">
      <id>https://gorgon.staging.palaceproject.io/a1qa-test/holds</id>
      <title>Holds</title>
      <updated>2024-06-15T12:00:00Z</updated>
      <link href="https://gorgon.staging.palaceproject.io/a1qa-test/holds" rel="self" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
      <entry schema:additionalType="http://schema.org/Book">
        <id>urn:librarysimplified.org/terms/id/TestLib%20ID/hold-reserved-001</id>
        <title>The Glass Menagerie Reimagined</title>
        <author><name>Tomoko Fujioka</name></author>
        <summary type="html">A modern retelling of Tennessee Williams&#8217; classic, set in contemporary Tokyo.</summary>
        <updated>2024-06-10T11:00:00Z</updated>
        <published>2024-04-01T00:00:00Z</published>
        <dcterms:language>en</dcterms:language>
        <dcterms:publisher>Sakura Literary</dcterms:publisher>
        <category term="http://librarysimplified.org/terms/fiction/Fiction" scheme="http://librarysimplified.org/terms/fiction/" label="Fiction"/>
        <link href="https://gorgon.staging.palaceproject.io/images/glass-menagerie-cover.jpg" type="image/jpeg" rel="http://opds-spec.org/image"/>
        <link href="https://gorgon.staging.palaceproject.io/images/glass-menagerie-thumb.jpg" type="image/jpeg" rel="http://opds-spec.org/image/thumbnail"/>
        <link href="https://gorgon.staging.palaceproject.io/a1qa-test/works/TestLib%20ID/hold-reserved-001/borrow" rel="http://opds-spec.org/acquisition/borrow" type="application/atom+xml;type=entry;profile=opds-catalog">
          <opds:indirectAcquisition type="application/vnd.adobe.adept+xml">
            <opds:indirectAcquisition type="application/epub+zip"/>
          </opds:indirectAcquisition>
          <opds:availability status="reserved" since="2024-06-05T10:00:00Z" until="2024-07-05T10:00:00Z"/>
          <opds:holds total="8" position="3"/>
          <opds:copies available="0" total="2"/>
        </link>
        <link href="https://gorgon.staging.palaceproject.io/a1qa-test/works/TestLib%20ID/hold-reserved-001/revoke" rel="http://librarysimplified.org/terms/rel/revoke" type="application/atom+xml;type=entry;profile=opds-catalog"/>
      </entry>
      <entry schema:additionalType="http://schema.org/Book">
        <id>urn:librarysimplified.org/terms/id/TestLib%20ID/hold-ready-002</id>
        <title>Quantum Cooking: Science in the Kitchen</title>
        <author><name>Dr. Amara Osei</name></author>
        <summary type="html">A cookbook that explains the physics and chemistry behind everyday cooking techniques.</summary>
        <updated>2024-06-14T16:00:00Z</updated>
        <published>2023-11-15T00:00:00Z</published>
        <dcterms:language>en</dcterms:language>
        <dcterms:publisher>Catalyst Books</dcterms:publisher>
        <category term="http://librarysimplified.org/terms/fiction/Nonfiction" scheme="http://librarysimplified.org/terms/fiction/" label="Nonfiction"/>
        <link href="https://gorgon.staging.palaceproject.io/images/quantum-cooking-cover.jpg" type="image/jpeg" rel="http://opds-spec.org/image"/>
        <link href="https://gorgon.staging.palaceproject.io/images/quantum-cooking-thumb.jpg" type="image/jpeg" rel="http://opds-spec.org/image/thumbnail"/>
        <link href="https://gorgon.staging.palaceproject.io/a1qa-test/works/TestLib%20ID/hold-ready-002/borrow" rel="http://opds-spec.org/acquisition/borrow" type="application/atom+xml;type=entry;profile=opds-catalog">
          <opds:indirectAcquisition type="application/vnd.readium.lcp.license.v1.0+json">
            <opds:indirectAcquisition type="application/epub+zip"/>
          </opds:indirectAcquisition>
          <opds:availability status="ready" since="2024-06-14T08:00:00Z" until="2024-06-17T08:00:00Z"/>
          <opds:holds total="5"/>
          <opds:copies available="1" total="3"/>
        </link>
      </entry>
    </feed>
    """
}

#endif
