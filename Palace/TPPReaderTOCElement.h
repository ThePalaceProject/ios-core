@class TPPReaderRendererOpaqueLocation;

@interface TPPReaderTOCElement : NSObject

@property (nonatomic, readonly) NSUInteger nestingLevel;
@property (nonatomic, readonly) TPPReaderRendererOpaqueLocation *opaqueLocation;
@property (nonatomic, readonly) NSString *title;

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

- (instancetype)initWithOpaqueLocation:(TPPReaderRendererOpaqueLocation *)opaqueLocation
                                 title:(NSString *)title
                          nestingLevel:(NSUInteger)nestingLevel;

@end
