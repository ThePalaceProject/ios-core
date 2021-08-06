#import "TPPOPDSEntryGroupAttributes.h"

@interface TPPOPDSEntryGroupAttributes ()

@property (nonatomic) NSURL *href;
@property (nonatomic) NSString *title;

@end

@implementation TPPOPDSEntryGroupAttributes

- (instancetype)initWithHref:(NSURL *const)href title:(NSString *const)title
{
  self = [super init];
  if(!self) return nil;
  
  if(!title) {
    @throw NSInvalidArgumentException;
  }
  
  self.href = href;
  self.title = [title copy];
  
  return self;
}

@end
