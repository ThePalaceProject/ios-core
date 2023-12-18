#import "NSDate+NYPLDateAdditions.h"
#import "TPPAsync.h"
#import "TPPOPDSEntry.h"
#import "TPPOPDSLink.h"
#import "TPPOPDSRelation.h"
#import "TPPSession.h"
#import "TPPXML.h"
#import "Palace-Swift.h"
#import "TPPOPDSFeed.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

@interface TPPOPDSFeed ()

@property (nonatomic) NSArray *entries;
@property (nonatomic) NSString *identifier;
@property (nonatomic) NSArray *links;
@property (nonatomic) NSString *title;
@property (nonatomic) TPPOPDSFeedType type;
@property (nonatomic) BOOL typeIsCached;
@property (nonatomic) NSDate *updated;
@property (nonatomic) NSMutableDictionary *licensor;
@property (nonatomic) NSString *authorizationIdentifier;

@end

static TPPOPDSFeedType TypeImpliedByEntry(TPPOPDSEntry *const entry)
{
  BOOL entryIsGrouped = NO;

  // NOTE: A catalog entry is an acquisition feed according to section 8 of
  // OPDS Catalog 1.1 if it contains at least one acquisition link.
  BOOL entryIsCatalogEntry = entry.acquisitions.count >= 1;

  for(TPPOPDSLink *const link in entry.links) {
    if([link.rel hasPrefix:@"http://opds-spec.org/acquisition"]) {
      // This also means we have an acquisition feed.
      entryIsCatalogEntry = YES;
    } else if([link.rel isEqualToString:TPPOPDSRelationGroup]) {
      entryIsGrouped = YES;
    }
  }
  
  if(entryIsGrouped && !entryIsCatalogEntry) {
    return TPPOPDSFeedTypeInvalid;
  }
  
  return (entryIsCatalogEntry
          ? (entryIsGrouped
             ? TPPOPDSFeedTypeAcquisitionGrouped
             : TPPOPDSFeedTypeAcquisitionUngrouped)
          : TPPOPDSFeedTypeNavigation);
}

@implementation TPPOPDSFeed

+ (void)withURL:(NSURL *)URL
shouldResetCache:(BOOL)shouldResetCache
completionHandler:(void (^)(TPPOPDSFeed *feed, NSDictionary *error))handler
{
  if(!handler) {
    @throw NSInvalidArgumentException;
  }

  __block NSURLRequest *request = nil;
  NSURLRequestCachePolicy cachePolicy;
  if (shouldResetCache) {
    cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  } else {
    cachePolicy = NSURLRequestUseProtocolCachePolicy;
  }

  if (URL == nil) {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                              summary:@"NYPLOPDSFeed: nil URL"
                             metadata:@{
                               @"shouldResetCache": @(shouldResetCache)
                             }];
    TPPAsyncDispatch(^{handler(nil, nil);});
    return;
  }

  request = [[[TPPNetworkExecutor shared] GET:URL
                                  cachePolicy:cachePolicy
                                  useTokenIfAvailable: NO
                                  completion:^(NSData *data, NSURLResponse *response, NSError *error) {

    if (error != nil) {
      // Note: NYPLNetworkExecutor already logged this error
      TPPAsyncDispatch(^{handler(nil, error.problemDocument.dictionaryValue);});
      return;
    }

    if (data == nil) {
      [TPPErrorLogger logErrorWithCode:TPPErrorCodeOpdsFeedNoData
                                summary:@"NYPLOPDSFeed: no data from server"
                               metadata:@{
                                 @"Request": [request loggableString],
                                 @"Response": response ?: @"N/A",
                               }];
      TPPAsyncDispatch(^{handler(nil, nil);});
      return;
    }

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
      NSHTTPURLResponse *httpResp = (NSHTTPURLResponse*)response;

      if (httpResp.statusCode < 200 || httpResp.statusCode > 299) {
        // this captures a situation where (e.g.) borrow requests to the
        // Brooklyn lib come back with a 500 status code, no error, and non-nil
        // data containing "An internal error occurred" plain text.
        NSString *msg = [NSString stringWithFormat:@"Got %ld HTTP status with no error object.", (long)httpResp.statusCode];

        NSString *dataString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

        NSDictionary *problemDocDict = nil;
        if (response.isProblemDocument) {
          problemDocDict = [NSJSONSerialization JSONObjectWithData:data options:(NSJSONReadingOptions)0 error:nil];
        }

        [TPPErrorLogger logNetworkError:error
                                   code:TPPErrorCodeApiCall
                                 summary:@"NYPLOPDSFeed: HTTP response error"
                                 request:request
                                response:response
                                metadata:@{
                                  @"receivedData": dataString ?: @"N/A",
                                  @"receivedDataLength (bytes)": @(data.length),
                                  @"problemDoc": problemDocDict ?: @"N/A",
                                  @"context": msg ?: @"N/A"
                                }];

        TPPAsyncDispatch(^{handler(nil, problemDocDict);});
        return;
      }
    }
    
    TPPXML *const feedXML = [TPPXML XMLWithData:data];
    if(!feedXML) {
      TPPLOG(@"Failed to parse data as XML.");
      [TPPErrorLogger logErrorWithCode:TPPErrorCodeFeedParseFail
                                summary:@"NYPLOPDSFeed: Failed to parse data as XML"
                               metadata:@{
                                 @"request": request.loggableString,
                                 @"response": response ?: @"N/A",
                               }];
      // this error may be nil
      NSDictionary *error = [NSJSONSerialization JSONObjectWithData:data options:(NSJSONReadingOptions)0 error:nil];
      TPPAsyncDispatch(^{handler(nil, error);});
      return;
    }
    
    TPPOPDSFeed *const feed = [[TPPOPDSFeed alloc] initWithXML:feedXML];
    if(!feed) {
      TPPLOG(@"Could not interpret XML as OPDS.");
      [TPPErrorLogger logErrorWithCode:TPPErrorCodeOpdsFeedParseFail
                                summary:@"NYPLOPDSFeed: Failed to parse XML as OPDS"
                               metadata:@{
                                 @"request": request.loggableString,
                                 @"response": response ?: @"N/A",
                               }];
      TPPAsyncDispatch(^{handler(nil, nil);});
      return;
    }
    
    TPPAsyncDispatch(^{handler(feed, nil);});
  }] originalRequest];
}

- (instancetype)initWithXML:(TPPXML *const)feedXML
{
  self = [super init];
  if(!self) return nil;
  
  if(!feedXML) {
    return nil;
  }
  
  // Sometimes we get back JUST an entry, and in that case we just want to construct a feed with
  // nothing set other than the entry.
  if ([feedXML.name isEqual:@"entry"]) {
    TPPOPDSEntry const* entry = [[TPPOPDSEntry alloc] initWithXML:feedXML];
    if (entry) {
      self.entries = @[entry];
      return self;
    } else {
      TPPLOG(@"Error creating single OPDS entry from feed.");
      return nil;
    }
  }
  
  if(!((self.identifier = [feedXML firstChildWithName:@"id"].value))) {
    TPPLOG(@"Missing required 'id' element.");
    return nil;
  }
  
  {
    NSMutableArray *const links = [NSMutableArray array];
    
    for(TPPXML *const linkXML in [feedXML childrenWithName:@"link"]) {
      TPPOPDSLink *const link = [[TPPOPDSLink alloc] initWithXML:linkXML];
      if(!link) {
        TPPLOG(@"Ignoring malformed 'link' element.");
        continue;
      }
      [links addObject:link];
    }
    
    self.links = links;
  }
  
  if(!((self.title = [feedXML firstChildWithName:@"title"].value))) {
    TPPLOG(@"Missing required 'title' element.");
    return nil;
  }
  
  {
    NSString *const updatedString = [feedXML firstChildWithName:@"updated"].value;
    if(!updatedString) {
      TPPLOG(@"Missing required 'updated' element.");
      return nil;
    }
    
    self.updated = [NSDate dateWithRFC3339String:updatedString];
    if(!self.updated) {
      TPPLOG(@"Element 'updated' does not contain an RFC 3339 date.");
      return nil;
    }
  }
  
  {
    NSMutableArray *const entries = [NSMutableArray array];
    
    for(TPPXML *const entryXML in [feedXML childrenWithName:@"entry"]) {
      TPPOPDSEntry *const entry = [[TPPOPDSEntry alloc] initWithXML:entryXML];
      if(!entry) {
        TPPLOG(@"Ingoring malformed 'entry' element.");
        continue;
      }
      [entries addObject:entry];
    }
    
    self.entries = entries;
  }
  
  {
    TPPXML *patronXML = [feedXML firstChildWithName:@"patron"];
    if (patronXML && patronXML.attributes.allValues.count>0) {
      NSString *barcode = patronXML.attributes[@"simplified:authorizationIdentifier"];
      self.authorizationIdentifier = barcode;
    }
  }
  
  {
    TPPXML *licensorXML = [feedXML firstChildWithName:@"licensor"];
    if (licensorXML && licensorXML.attributes.allValues.count>0) {
      NSString *vendor = licensorXML.attributes[@"drm:vendor"];
      TPPXML *tokenXML = [licensorXML firstChildWithName:@"clientToken"];
      
      if (tokenXML) {
        NSString *clientToken = tokenXML.value;
        self.licensor = @{@"vendor":vendor,
                          @"clientToken":clientToken}.mutableCopy;
      } else {
        TPPLOG(@"Licensor not saved. Error parsing clientToken into XML.");
      }
    } else {
      TPPLOG(@"No Licensor found in OPDS feed. Moving on.");
    }
  }
  
  return self;
}

- (TPPOPDSFeedType)type
{
  if(self.typeIsCached) {
    return _type;
  }
  
  self.typeIsCached = YES;
  
  if(self.entries.count == 0) {
    _type = TPPOPDSFeedTypeAcquisitionUngrouped;
    return _type;
  }
  
  TPPOPDSFeedType const provisionalType = TypeImpliedByEntry(self.entries.firstObject);
  
  if(provisionalType == TPPOPDSFeedTypeInvalid) {
    _type = TPPOPDSFeedTypeInvalid;
    return _type;
  }
  
  for(unsigned int i = 1; i < self.entries.count; ++i) {
    if(TypeImpliedByEntry(self.entries[i]) != provisionalType) {
      _type = TPPOPDSFeedTypeInvalid;
      return _type;
    }
  }
  
  _type = provisionalType;
  return _type;
}

@end
