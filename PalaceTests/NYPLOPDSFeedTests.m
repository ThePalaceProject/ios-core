@import XCTest;

#import "NSDate+NYPLDateAdditions.h"
#import "TPPOPDSFeed.h"
#import "TPPXML.h"

@interface TPPOPDSFeedTests : XCTestCase

@property (nonatomic) TPPOPDSFeed *feed;

@end

@implementation TPPOPDSFeedTests

- (void)setUp
{
  [super setUp];
  
  NSData *const data =
    [NSData dataWithContentsOfFile:
     [[NSBundle bundleForClass:[self class]] pathForResource:@"main" ofType:@"xml"]];
  assert(data);
  
  TPPXML *const feedXML = [TPPXML XMLWithData:data];
  assert(feedXML);
  
  self.feed = [[TPPOPDSFeed alloc] initWithXML:feedXML];
  assert(self.feed);
}

- (void)tearDown
{
  [super tearDown];
  
  self.feed = nil;
}

- (void)testHandlesNilInit
{
  XCTAssertNil([[TPPOPDSFeed alloc] initWithXML:nil]);
}

- (void)testEntriesPresent
{
  XCTAssert(self.feed.entries);
}

- (void)testTypeAcquisitionUngrouped
{
  XCTAssertEqual(self.feed.type, TPPOPDSFeedTypeAcquisitionUngrouped);
}

- (void)testIdentifier
{
  XCTAssertEqualObjects(self.feed.identifier, @"http://localhost/main");
}

- (void)testLinkCount
{
  XCTAssertEqual(self.feed.links.count, 2U);
}

- (void)testTitle
{
  XCTAssertEqualObjects(self.feed.title, @"The Big Front Page");
}

- (void)testUpdated
{
  NSDate *const date = self.feed.updated;
  XCTAssert(date);
  
  NSDateComponents *const dateComponents = [date UTCComponents];
  XCTAssertEqual(dateComponents.year, 2014);
  XCTAssertEqual(dateComponents.month, 6);
  XCTAssertEqual(dateComponents.day, 2);
  XCTAssertEqual(dateComponents.hour, 16);
  XCTAssertEqual(dateComponents.minute, 59);
  XCTAssertEqual(dateComponents.second, 57);
}

@end
