@class TPPXML;

@interface TPPOPDSLink : NSObject

@property (nonatomic, readonly) NSDictionary *attributes;
@property (nonatomic, readonly) NSURL *href;
@property (nonatomic, readonly) NSString *rel; // nilable
@property (nonatomic, readonly) NSString *type; // nilable
@property (nonatomic, readonly) NSString *hreflang; // nilable
@property (nonatomic, readonly) NSString *title; // nilable

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

// designated initializer
- (instancetype)initWithXML:(TPPXML *)linkXML;

@end
