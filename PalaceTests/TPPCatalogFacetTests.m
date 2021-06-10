@import XCTest;

#import "TPPCatalogFacet.h"
#import "TPPOPDSLink.h"
#import "TPPXML.h"

@interface TPPCatalogFacetTests : XCTestCase

@end

static TPPOPDSLink *biographyXML = nil;
static TPPOPDSLink *scienceFictionXML = nil;

@implementation TPPCatalogFacetTests

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wgnu"

+ (void)setUp
{
  {
    NSString *const XMLString = (@"<link rel=\"http://opds-spec.org/facet\""
                                 @" href=\"http://example.com/biography\""
                                 @" title=\"Biography\""
                                 @" opds:facetGroup=\"Categories\"/>");
    
    TPPXML *const XML = [TPPXML XMLWithData:[XMLString dataUsingEncoding:NSUTF8StringEncoding]];
    
    biographyXML = [[TPPOPDSLink alloc] initWithXML:XML];
    
    assert(biographyXML);
  }
  
  {
    NSString *const XMLString = (@"<link rel=\"http://opds-spec.org/facet\""
                                 @" href=\"http://example.com/sci-fi\""
                                 @" title=\"Science-Fiction\""
                                 @" opds:activeFacet=\"true\"/>");
    
    TPPXML *const XML = [TPPXML XMLWithData:[XMLString dataUsingEncoding:NSUTF8StringEncoding]];
    
    scienceFictionXML = [[TPPOPDSLink alloc] initWithXML:XML];
    
    assert(scienceFictionXML);
  }
}

- (void)testBiography
{
  TPPCatalogFacet *const facet = [TPPCatalogFacet catalogFacetWithLink:biographyXML];
  
  XCTAssert(facet);
  
  XCTAssert(!facet.active);
  
  XCTAssertEqualObjects(facet.href, [NSURL URLWithString:@"http://example.com/biography"]);
  
  XCTAssertEqualObjects(facet.title, @"Biography");
}

- (void)testScienceFiction
{
  TPPCatalogFacet *const facet = [TPPCatalogFacet catalogFacetWithLink:scienceFictionXML];
  
  XCTAssert(facet);
  
  XCTAssert(facet.active);
  
  XCTAssertEqualObjects(facet.href, [NSURL URLWithString:@"http://example.com/sci-fi"]);
  
  XCTAssertEqualObjects(facet.title, @"Science-Fiction");
}

#pragma GCC diagnostic pop

@end
