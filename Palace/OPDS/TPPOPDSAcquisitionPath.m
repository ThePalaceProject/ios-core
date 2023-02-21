#import "TPPOPDSIndirectAcquisition.h"
#import "TPPOPDSAcquisitionPath.h"
#import "Palace-Swift.h"

NSString * const _Nonnull ContentTypeOPDSCatalog = @"application/atom+xml;type=entry;profile=opds-catalog";
NSString * const _Nonnull ContentTypeAdobeAdept = @"application/vnd.adobe.adept+xml";
NSString * const _Nonnull ContentTypeBearerToken = @"application/vnd.librarysimplified.bearer-token+json";
NSString * const _Nonnull ContentTypeEpubZip = @"application/epub+zip";
NSString * const _Nonnull ContentTypeFindaway = @"application/vnd.librarysimplified.findaway.license+json";
NSString * const _Nonnull ContentTypeOpenAccessAudiobook = @"application/audiobook+json";
NSString * const _Nonnull ContentTypeOpenAccessPDF = @"application/pdf";
NSString * const _Nonnull ContentTypeFeedbooksAudiobook = @"application/audiobook+json;profile=\"http://www.feedbooks.com/audiobooks/access-restriction\"";
NSString * const _Nonnull ContentTypeOctetStream = @"application/octet-stream";
NSString * const _Nonnull ContentTypeOverdriveAudiobook = @"application/vnd.overdrive.circulation.api+json;profile=audiobook";
NSString * const _Nonnull ContentTypeOverdriveAudiobookActual = @"application/json";
NSString * const _Nonnull ContentTypeReadiumLCP = @"application/vnd.readium.lcp.license.v1.0+json";
NSString * const _Nonnull ContentTypeReadiumLCPPDF = @"application/pdf";
NSString * const _Nonnull ContentTypePDFLCP = @"application/pdf+lcp";
NSString * const _Nonnull ContentTypeAudiobookLCP = @"application/audiobook+lcp";
NSString * const _Nonnull ContentTypeAudiobookZip = @"application/audiobook+zip";
NSString * const _Nonnull ContentTypeBiblioboard = @"application/json";

@interface TPPOPDSAcquisitionPath ()

@property (nonatomic) TPPOPDSAcquisitionRelation relation;
@property (nonatomic, nonnull) NSArray<NSString *> *types;
@property (nonatomic, nonnull) NSURL *url;

@end

@implementation TPPOPDSAcquisitionPath : NSObject

- (instancetype _Nonnull)initWithRelation:(TPPOPDSAcquisitionRelation const)relation
                                    types:(NSArray<NSString *> *const _Nonnull)types
                                      url:(NSURL *const _Nonnull)url
{
  self = [super init];

  self.relation = relation;
  self.types = types;
  self.url = url;

  return self;
}

+ (NSSet<NSString *> *_Nonnull)supportedTypes
{
  static NSSet<NSString *> *types = nil;

  if (!types) {
    types = [NSSet setWithArray:@[
      ContentTypeOPDSCatalog,
      ContentTypeBearerToken,
      ContentTypeEpubZip,
#if FEATURE_DRM_CONNECTOR
      ContentTypeAdobeAdept,
#endif
      ContentTypeFindaway,
      ContentTypeOpenAccessAudiobook,
      ContentTypeOpenAccessPDF,
      ContentTypeFeedbooksAudiobook,
      ContentTypeOverdriveAudiobook,
      ContentTypeOctetStream,
      ContentTypeBiblioboard,
#if LCP
      ContentTypeReadiumLCP,
      ContentTypeAudiobookLCP,
      ContentTypeReadiumLCPPDF,
#endif
      ContentTypeAudiobookZip
    ]];
  }

#if FEATURE_DRM_CONNECTOR
  // Adobe DRM crashes the app when certificate is expired.
  if ([AdobeCertificate.defaultCertificate hasExpired] == YES) {
    NSMutableSet<NSString *> *mutableTypes = [types mutableCopy];
    [mutableTypes removeObject:ContentTypeAdobeAdept];
    return [mutableTypes copy];
  }
#endif
  return types;
}
  
+ (NSSet<NSString *> *_Nonnull)supportedSubtypesForType:(NSString *)type
{
  static NSDictionary<NSString *, NSSet<NSString *> *> *subtypesForTypes = nil;
  /**
   Subtypes are the supported types of nested and indirect acquisitions.
   For example:
   - When we open LCP library, we receive a feed of type ContentTypeOPDSCatalog containing ContentTypeReadiumLCP subtypes in it.
   - When we tap an LCP-protected book in the app, the app doesn't download the book, but downloads a license file of type ContentTypeReadiumLCP
    with content subtype of ContentTypeEpubZip if it is a book or ContentTypeAudiobookZip for an audiobook;
    this file is later fulfilled by LCP library and we get a real epub book or audiobook.
   */
  if (!subtypesForTypes) {
    subtypesForTypes = @{
      ContentTypeOPDSCatalog: [NSSet setWithArray:@[
        ContentTypeAdobeAdept,
        ContentTypeBearerToken,
        ContentTypeFindaway,
        ContentTypeEpubZip,
        ContentTypeOpenAccessPDF,
        ContentTypeOpenAccessAudiobook,
        ContentTypeFeedbooksAudiobook,
        ContentTypeOverdriveAudiobook,
        ContentTypeOctetStream,
        ContentTypeReadiumLCP,
        ContentTypeAudiobookZip
      ]],
      ContentTypeReadiumLCP: [NSSet setWithArray:@[
        ContentTypeEpubZip,
        ContentTypeAudiobookZip,
        ContentTypeAudiobookLCP,
        ContentTypeReadiumLCPPDF
      ]],
      ContentTypeAdobeAdept: [NSSet setWithArray:@[ContentTypeEpubZip]],
      ContentTypeBearerToken: [NSSet setWithArray:@[
        ContentTypeEpubZip,
        ContentTypeOpenAccessPDF,
        ContentTypeOpenAccessAudiobook
      ]]
    };
  }
  
  NSSet<NSString *> *types = subtypesForTypes[type];
  
  return types ?: [NSSet set];
}

+ (NSSet<NSString *> *_Nonnull)audiobookTypes {
  return [NSSet setWithArray:@[ContentTypeFindaway,
                               ContentTypeOpenAccessAudiobook,
                               ContentTypeFeedbooksAudiobook,
                               ContentTypeOverdriveAudiobook,
                               ContentTypeAudiobookZip,
                               ContentTypeAudiobookLCP]];
}

- (BOOL)isEqual:(id const)object
{
  if (![object isKindOfClass:[TPPOPDSAcquisitionPath class]]) {
    return NO;
  }

  TPPOPDSAcquisitionPath *const path = object;

  return self.relation == path.relation && [self.types isEqualToArray:path.types];
}

- (NSUInteger)hash
{
  NSUInteger const prime = 31;
  NSUInteger result = 1;

  result = prime * result + self.relation;
  result = prime * result + [self.types hash];

  return result;
}

NSMutableArray<NSMutableArray<NSString *> *> *_Nonnull
mutableTypePaths(
  TPPOPDSIndirectAcquisition *const _Nonnull indirectAcquisition,
  NSSet<NSString *> *const _Nonnull allowedTypes)
{
  if ([allowedTypes containsObject:indirectAcquisition.type]) {
    if (indirectAcquisition.indirectAcquisitions.count == 0) {
      return [NSMutableArray arrayWithObject:[NSMutableArray arrayWithObject:indirectAcquisition.type]];
    } else {
      NSMutableSet<NSString *> *supportedSubtypes = [[TPPOPDSAcquisitionPath supportedSubtypesForType:indirectAcquisition.type] mutableCopy];
      [supportedSubtypes intersectSet:allowedTypes];
      NSMutableArray<NSMutableArray<NSString *> *> *const mutableTypePathsResults = [NSMutableArray array];
      for (TPPOPDSIndirectAcquisition *const nestedIndirectAcquisition in indirectAcquisition.indirectAcquisitions) {
        if (![supportedSubtypes containsObject:nestedIndirectAcquisition.type]) {
          continue;
        }
        for (NSMutableArray<NSString *> *const mutableTypePath
             in mutableTypePaths(nestedIndirectAcquisition, allowedTypes))
        {
          // This operation is not O(1) as desired but it is close enough for our purposes.
          [mutableTypePath insertObject:indirectAcquisition.type atIndex:0];
          [mutableTypePathsResults addObject:mutableTypePath];
        }
      }
      return mutableTypePathsResults;
    }
  } else {
    return [NSMutableArray array];
  }
}


+ (NSArray<TPPOPDSAcquisitionPath *> *_Nonnull)
supportedAcquisitionPathsForAllowedTypes:(NSSet<NSString *> *_Nonnull)types
allowedRelations:(TPPOPDSAcquisitionRelationSet)relations
acquisitions:(NSArray<TPPOPDSAcquisition *> *_Nonnull)acquisitions
{
  NSMutableSet *const mutableAcquisitionPathSet = [NSMutableSet set];
  NSMutableArray *const mutableAcquisitionPaths = [NSMutableArray array];

    for (TPPOPDSAcquisition *const acquisition in acquisitions) {
      BOOL containsType = [types containsObject:acquisition.type];
      BOOL containsRelation = NYPLOPDSAcquisitionRelationSetContainsRelation(relations, acquisition.relation);
      BOOL shouldAdd = containsType && containsRelation;
        
      if (!shouldAdd) {
        continue;
      }
        
      if (acquisition.indirectAcquisitions.count == 0) {
        [mutableAcquisitionPaths addObject:
         [[TPPOPDSAcquisitionPath alloc]
          initWithRelation:acquisition.relation
          types:@[acquisition.type]
          url:acquisition.hrefURL]];
          continue;
      }
        
      NSMutableSet<NSString *> *supportedSubtypes = [[TPPOPDSAcquisitionPath
                                                      supportedSubtypesForType:acquisition.type]
                                                     mutableCopy];
      [supportedSubtypes intersectSet:types];
        
      for (TPPOPDSIndirectAcquisition *const indirectAcquisition in acquisition.indirectAcquisitions) {
            
        if (![supportedSubtypes containsObject:indirectAcquisition.type]) {
                continue;
        }
            
        for (NSMutableArray<NSString *> *const mutableTypePath in mutableTypePaths(indirectAcquisition, types)) {
                
          [mutableTypePath insertObject:acquisition.type atIndex:0];
                
          TPPOPDSAcquisitionPath *const acquisitionPath = [[TPPOPDSAcquisitionPath alloc]
                                                            initWithRelation:acquisition.relation
                                                            types:[mutableTypePath copy]
                                                            url:acquisition.hrefURL];
            
            if (![mutableAcquisitionPathSet containsObject:acquisitionPath]) {
                [mutableAcquisitionPaths addObject:acquisitionPath];
                [mutableAcquisitionPathSet addObject:acquisitionPath];
            }
                
        } // mutableTypePath in mutableTypePaths(indirectAcquisition, types)
      } // indirectAcquisition in acquisition.indirectAcquisitions
    } // acquisition in acquisitions

  return [mutableAcquisitionPaths copy];
}

@end
