@import XCTest;

#import "TPPOPDSEntry.h"
#import "TPPOPDSFeed.h"
#import "TPPOPDSLink.h"
#import "TPPXML.h"

@interface TPPOPDSLinkTests : XCTestCase

@property (nonatomic) NSArray *links;

@end

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wgnu"

@implementation TPPOPDSLinkTests

- (void)setUp
{
  [super setUp];
  
  NSData *const data = [NSData dataWithContentsOfFile:
                        [[NSBundle bundleForClass:[self class]]
                         pathForResource:@"single_entry"
                         ofType:@"xml"]];
  assert(data);
  
  TPPXML *const feedXML = [TPPXML XMLWithData:data];
  assert(feedXML);
  
  TPPOPDSFeed *const feed = [[TPPOPDSFeed alloc] initWithXML:feedXML];
  assert(feed);
  
  self.links = ((TPPOPDSEntry *) feed.entries[0]).links;
  assert(self.links);
}

- (void)tearDown
{
  [super tearDown];
  
  self.links = nil;
}

- (void)testHandlesNilInit
{
  XCTAssertNil([[TPPOPDSLink alloc] initWithXML:nil]);
}

- (void)testCount
{
  XCTAssertEqual(self.links.count, 6U);
}

- (void)testLink0
{
  TPPOPDSLink *const link = self.links[0];
  XCTAssertEqualObjects(link.href, [NSURL URLWithString:
                                    @"http://localhost/works/4c87a3af9d312c5fd2d44403efc57e2b"]);
  XCTAssertNil(link.rel);
  XCTAssertNil(link.type);
  XCTAssertNil(link.hreflang);
  XCTAssertNil(link.title);
}

- (void)testLink1
{
  TPPOPDSLink *const link = self.links[1];
  XCTAssertEqualObjects(link.href, [NSURL URLWithString:
                                    @"http://www.gutenberg.org/ebooks/177.epub.noimages"]);
  XCTAssertEqualObjects(link.rel, @"http://opds-spec.org/acquisition/open-access");
  XCTAssertEqualObjects(link.type, @"application/epub+zip");
  XCTAssertNil(link.hreflang);
  XCTAssertNil(link.title);
}

- (void)testLink2
{
  TPPOPDSLink *const link = self.links[2];
  XCTAssertEqualObjects(link.href, [NSURL URLWithString:
                                    @"http://covers.openlibrary.org/b/id/244619-S.jpg"]);
  XCTAssertEqualObjects(link.rel, @"http://opds-spec.org/image/thumbnail");
  XCTAssertNil(link.type);
  XCTAssertNil(link.hreflang);
  XCTAssertNil(link.title);
}

- (void)testLink3
{
  TPPOPDSLink *const link = self.links[3];
  XCTAssertEqualObjects(link.href, [NSURL URLWithString:
                                    @"http://covers.openlibrary.org/b/id/244619-L.jpg"]);
  XCTAssertEqualObjects(link.rel, @"http://opds-spec.org/image");
  XCTAssertNil(link.type);
  XCTAssertNil(link.hreflang);
  XCTAssertNil(link.title);
}

- (void)testLink4
{
  TPPOPDSLink *const link = self.links[4];
  XCTAssertEqualObjects(link.href, [NSURL URLWithString:@"http://localhost/lanes/Nonfiction"]);
  XCTAssertEqualObjects(link.rel, @"collection");
  XCTAssertNil(link.type);
  XCTAssertNil(link.hreflang);
  XCTAssertEqualObjects(link.title, @"Nonfiction");
}

@end

#pragma GCC diagnostic pop

