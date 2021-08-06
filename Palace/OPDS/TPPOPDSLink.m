#import "NSDate+NYPLDateAdditions.h"
#import "TPPXML.h"
#import "Palace-Swift.h"

#import "TPPOPDSLink.h"

@interface TPPOPDSLink ()

@property (nonatomic) NSDictionary *attributes;
@property (nonatomic) NSURL *href;
@property (nonatomic) NSString *rel;
@property (nonatomic) NSString *type;
@property (nonatomic) NSString *hreflang;
@property (nonatomic) NSString *title;

@end

@implementation TPPOPDSLink

- (instancetype)initWithXML:(TPPXML *const)linkXML
{
  self = [super init];
  if(!self) return nil;
  
  {
    NSString *const hrefString = linkXML.attributes[@"href"];
    if(!hrefString) {
      TPPLOG(@"Missing required 'href' attribute.");
      return nil;
    }
    
    if(!((self.href = [NSURL URLWithString:hrefString]))) {
      // Atom requires support for RFC 3986, but CFURL and NSURL only support RFC 2396. As such, a
      // valid URI may be rejected in extremely rare cases.
      TPPLOG(@"'href' attribute does not contain an RFC 2396 URI.");
      return nil;
    }
  }
  
  self.attributes = linkXML.attributes;
  self.rel = linkXML.attributes[@"rel"];
  self.type = linkXML.attributes[@"type"];
  self.hreflang = linkXML.attributes[@"hreflang"];
  self.title = linkXML.attributes[@"title"];

  return self;
}

@end
