#import "TPPReaderTOCElement.h"

@interface TPPReaderTOCElement ()

@property (nonatomic) NSUInteger nestingLevel;
@property (nonatomic) TPPReaderRendererOpaqueLocation *opaqueLocation;
@property (nonatomic) NSString *title;

@end

@implementation TPPReaderTOCElement

- (instancetype)initWithOpaqueLocation:(TPPReaderRendererOpaqueLocation *const)opaqueLocation
                                 title:(NSString *const)title
                          nestingLevel:(NSUInteger const)nestingLevel
{
  self = [super init];
  if(!self) return nil;
  
  if(!opaqueLocation) {
    @throw NSInvalidArgumentException;
  }
  
  self.nestingLevel = nestingLevel;
  self.opaqueLocation = opaqueLocation;
  self.title = title;
  
  return self;
}

@end
