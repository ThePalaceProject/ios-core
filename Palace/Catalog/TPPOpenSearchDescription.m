#import "TPPAsync.h"
#import "TPPSession.h"
#import "TPPXML.h"
#import "NSString+TPPStringAdditions.h"
#import "Palace-Swift.h"

#import "TPPOpenSearchDescription.h"

@interface TPPOpenSearchDescription ()

@property (nonatomic) NSString *humanReadableDescription;
@property (nonatomic) NSString *OPDSURLTemplate;
@property (nonatomic) NSArray *books;

@end

@implementation TPPOpenSearchDescription

+ (void)withURL:(NSURL *const)URL
shouldResetCache:(BOOL)shouldResetCache
completionHandler:(void (^)(TPPOpenSearchDescription *))handler
{
  if(!handler) {
    @throw NSInvalidArgumentException;
  }
  
  [[TPPSession sharedSession]
   withURL:URL
   shouldResetCache:shouldResetCache
   completionHandler:^(NSData *const data, __unused NSURLResponse *response, __unused NSError *error) {
     if(!data) {
       TPPLOG(@"Failed to retrieve data.");
       TPPAsyncDispatch(^{handler(nil);});
       return;
     }
     
     TPPXML *const XML = [TPPXML XMLWithData:data];
//     NSString *datcat = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] substringToIndex:100];
//     NSDictionary *errData = @{@"data": [NSString stringWithFormat:@"%@...", datcat]};
     if(!XML) {
       TPPLOG(@"Failed to parse data as XML.");
       TPPAsyncDispatch(^{handler(nil);});
       return;
     }
     
     TPPOpenSearchDescription *const description =
       [[TPPOpenSearchDescription alloc] initWithXML:XML];
     
     if(!description) {
       TPPLOG(@"Failed to interpret XML as OpenSearch description document.");
       TPPAsyncDispatch(^{handler(nil);});
       return;
     }
     
     TPPAsyncDispatch(^{handler(description);});
   }];
}

- (instancetype)initWithXML:(TPPXML *const)OSDXML
{
  self = [super init];
  if(!self) return nil;
  
  self.humanReadableDescription = [OSDXML firstChildWithName:@"Description"].value;
  
  if(!self.humanReadableDescription) {
    TPPLOG(@"Missing required description element.");
    return nil;
  }
  
  for(TPPXML *const UrlXML in [OSDXML childrenWithName:@"Url"]) {
    NSString *const type = UrlXML.attributes[@"type"];
    if(type && [type rangeOfString:@"opds-catalog"].location != NSNotFound) {
      self.OPDSURLTemplate = UrlXML.attributes[@"template"];
      break;
    }
  }
  
  if(!self.OPDSURLTemplate) {
    TPPLOG(@"Missing expected OPDS URL.");
    return nil;
  }
  
  return self;
}

- (instancetype)initWithTitle:(NSString *)title books:(NSArray *)books
{
  self = [super init];
  if(!self) return nil;
  self.books = books;
  self.humanReadableDescription = title;
  return self;
}

- (NSURL *)OPDSURLForSearchingString:(NSString *)searchString
{
  NSString *urlStr = [self.OPDSURLTemplate
                      stringByReplacingOccurrencesOfString:@"{searchTerms}"
                      withString:[searchString stringURLEncodedAsQueryParamValue]];
  return [NSURL URLWithString:urlStr];
}

@end
