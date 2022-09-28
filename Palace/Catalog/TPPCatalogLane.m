#import "TPPCatalogLane.h"
#import "Palace-Swift.h"

@interface TPPCatalogLane ()

@property (nonatomic) NSArray *books;
@property (nonatomic) NSURL *subsectionURL;
@property (nonatomic) NSString *title;

@end

@implementation TPPCatalogLane

- (instancetype)initWithBooks:(NSArray *const)books
                subsectionURL:(NSURL *const)subsectionURL
                        title:(NSString *const)title
{
  self = [super init];
  if(!self) return nil;
  
  if(!(books && title)) {
    @throw NSInvalidArgumentException;
  }
  
  for(id object in books) {
    if(![object isKindOfClass:[TPPBook class]]) {
      @throw NSInvalidArgumentException;
    }

    TPPBook *const book = object;

    if(!book.defaultAcquisition) {
      // The application is not able to support this, so we ignore it.
      continue;
    }
  }
  
  self.books = books;
  self.subsectionURL = subsectionURL;
  self.title = title;
  
  return self;
}

@end
