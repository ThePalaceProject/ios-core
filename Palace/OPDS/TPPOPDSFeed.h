@class TPPXML;

typedef NS_ENUM(NSInteger, TPPOPDSFeedType) {
  TPPOPDSFeedTypeInvalid,
  TPPOPDSFeedTypeAcquisitionGrouped,
  TPPOPDSFeedTypeAcquisitionUngrouped,
  TPPOPDSFeedTypeNavigation
};

@interface TPPOPDSFeed : NSObject

@property (nonatomic, readonly) NSArray *entries;
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSArray *links;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) TPPOPDSFeedType type;
@property (nonatomic, readonly) NSDate *updated;
@property (nonatomic, readonly) NSDictionary *licensor;
@property (nonatomic, readonly) NSString *authorizationIdentifier;

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

/// Executes a GET request for the given URL unless the last path component
/// is `borrow`, in which case it executes a PUT.
/// @param URL The URL to contact.
/// @param shouldResetCache Pass YES to wipe the whole cache.
/// @param handler The completion handler that will always be called at the
/// end of the process.
+ (void) withURL:(NSURL *)URL
 shouldResetCache:(BOOL)shouldResetCache
useTokenIfAvailable:(BOOL)useTokenIfAvailable
completionHandler:(void (^)(TPPOPDSFeed *feed, NSDictionary *error))handler;

/// Designated initializer.
- (instancetype)initWithXML:(TPPXML *)feedXML;

@end
