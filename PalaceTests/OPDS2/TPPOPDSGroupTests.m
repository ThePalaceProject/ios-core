@import XCTest;

#import "TPPOPDSGroup.h"

@interface TPPOPDSGroupTests : XCTestCase
@end

@implementation TPPOPDSGroupTests

- (void)testInitStoresProperties
{
  NSURL *href = [NSURL URLWithString:@"https://example.com/group"];
  TPPOPDSGroup *group = [[TPPOPDSGroup alloc] initWithEntries:@[] href:href title:@"Group Title"];

  XCTAssertNotNil(group);
  XCTAssertEqualObjects(group.href, href);
  XCTAssertEqualObjects(group.title, @"Group Title");
  XCTAssertEqual(group.entries.count, 0U);
}

- (void)testInitThrowsForInvalidEntryTypes
{
  NSArray *badEntries = @[ @"not-an-entry" ];
  NSURL *href = [NSURL URLWithString:@"https://example.com/group"];

  XCTAssertThrowsSpecificNamed([[TPPOPDSGroup alloc] initWithEntries:badEntries
                                                                href:href
                                                               title:@"Group Title"],
                               NSException,
                               NSInvalidArgumentException);
}

- (void)testInitThrowsForNilArguments
{
  NSURL *href = [NSURL URLWithString:@"https://example.com/group"];

  // Nil entries
  XCTAssertThrowsSpecificNamed([[TPPOPDSGroup alloc] initWithEntries:nil
                                                                href:href
                                                               title:@"Group Title"],
                               NSException,
                               NSInvalidArgumentException);

  // Nil href
  XCTAssertThrowsSpecificNamed([[TPPOPDSGroup alloc] initWithEntries:@[]
                                                                href:nil
                                                               title:@"Group Title"],
                               NSException,
                               NSInvalidArgumentException);

  // Nil title
  XCTAssertThrowsSpecificNamed([[TPPOPDSGroup alloc] initWithEntries:@[]
                                                                href:href
                                                               title:nil],
                               NSException,
                               NSInvalidArgumentException);
}

@end

