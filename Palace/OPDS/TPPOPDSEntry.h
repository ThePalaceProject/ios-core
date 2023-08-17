@class TPPOPDSAcquisition;
@class TPPOPDSCategory;
@class TPPOPDSEntryGroupAttributes;
@class NYPLOPDSEvent;
@class TPPXML;
@class TPPOPDSLink;

@interface TPPOPDSEntry : NSObject

@property (nonatomic, readonly) NSArray<TPPOPDSAcquisition *> *acquisitions;
@property (nonatomic, readonly) NSString *alternativeHeadline; // nilable
@property (nonatomic, readonly) NSArray *authorStrings;
@property (nonatomic, readonly) NSArray<TPPOPDSLink *> *authorLinks;
@property (nonatomic, readonly) TPPOPDSLink *seriesLink;
@property (nonatomic, readonly) NSArray<TPPOPDSCategory *> *categories;
@property (nonatomic, readonly) TPPOPDSEntryGroupAttributes *groupAttributes; // nilable
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSArray *links;
@property (nonatomic, readonly) TPPOPDSLink *annotations;
@property (nonatomic, readonly) TPPOPDSLink *alternate;
@property (nonatomic, readonly) TPPOPDSLink *relatedWorks;
@property (nonatomic, readonly) TPPOPDSAcquisition *previewLink;
@property (nonatomic, readonly) NSURL *analytics;
@property (nonatomic, readonly) NSString *providerName; // nilable
@property (nonatomic, readonly) NSDate *published; // nilable
@property (nonatomic, readonly) NSString *publisher; // nilable
@property (nonatomic, readonly) NSString *summary; // nilable
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSDate *updated;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<NSString *>*> *contributors;
@property (nonatomic, readonly) TPPOPDSLink *timeTrackingLink;

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

// designated initializer
- (instancetype)initWithXML:(TPPXML *)entryXML;

@end
