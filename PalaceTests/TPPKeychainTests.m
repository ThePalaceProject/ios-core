@import XCTest;

#import "TPPKeychain.h"

@interface TPPKeychainTests : XCTestCase

@end

@implementation TPPKeychainTests

- (void)setUp
{
  [super setUp];
}

- (void)tearDown
{
  [super tearDown];
}

- (void)test0
{
  [[TPPKeychain sharedKeychain] setObject:@"foo" forKey:@"D5AAFADD-E036-4CA6-BBC7-B5962455831D"];
  XCTAssertEqualObjects(@"foo",
                        [[TPPKeychain sharedKeychain]
                         objectForKey:@"D5AAFADD-E036-4CA6-BBC7-B5962455831D"]);

  [[TPPKeychain sharedKeychain] setObject:@"bar" forKey:@"D5AAFADD-E036-4CA6-BBC7-B5962455831D"];
  XCTAssertEqualObjects(@"bar",
                        [[TPPKeychain sharedKeychain]
                         objectForKey:@"D5AAFADD-E036-4CA6-BBC7-B5962455831D"]);

  [[TPPKeychain sharedKeychain] setObject:@"baz" forKey:@"7D6F207E-9D04-4EE8-9D96-6E07777376C0"];
  XCTAssertEqualObjects(@"baz",
                        [[TPPKeychain sharedKeychain]
                         objectForKey:@"7D6F207E-9D04-4EE8-9D96-6E07777376C0"]);

  XCTAssertEqualObjects(@"bar",
                        [[TPPKeychain sharedKeychain]
                         objectForKey:@"D5AAFADD-E036-4CA6-BBC7-B5962455831D"]);

  [[TPPKeychain sharedKeychain] removeObjectForKey:@"D5AAFADD-E036-4CA6-BBC7-B5962455831D"];
  XCTAssertNil([[TPPKeychain sharedKeychain]
                objectForKey:@"D5AAFADD-E036-4CA6-BBC7-B5962455831D"]);
  
  XCTAssertEqualObjects(@"baz",
                        [[TPPKeychain sharedKeychain]
                         objectForKey:@"7D6F207E-9D04-4EE8-9D96-6E07777376C0"]);
  
  [[TPPKeychain sharedKeychain] removeObjectForKey:@"7D6F207E-9D04-4EE8-9D96-6E07777376C0"];
  XCTAssertNil([[TPPKeychain sharedKeychain]
                objectForKey:@"7D6F207E-9D04-4EE8-9D96-6E07777376C0"]);
}

@end
