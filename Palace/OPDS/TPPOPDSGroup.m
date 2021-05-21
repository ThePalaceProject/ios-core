#import "TPPOPDSEntry.h"

#import "TPPOPDSGroup.h"

@interface TPPOPDSGroup ()

@property (nonatomic) NSArray *entries;
@property (nonatomic) NSURL *href;
@property (nonatomic) NSString *title;

@end

@implementation TPPOPDSGroup

- (instancetype)initWithEntries:(NSArray *const)entries
                           href:(NSURL *const)href
                          title:(NSString *const)title
{
  self = [super init];
  if(!self) return nil;
  
  if(!(entries && href && title)) {
    @throw NSInvalidArgumentException;
  }
  
  for(id object in entries) {
    if(![object isKindOfClass:[TPPOPDSEntry class]]) {
      @throw NSInvalidArgumentException;
    }
  }
  
  self.entries = entries;
  self.href = href;
  self.title = [title copy];
  
  return self;
}

@end
