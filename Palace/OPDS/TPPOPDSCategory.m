#import "TPPOPDSCategory.h"

@interface TPPOPDSCategory ()

@property (nonatomic, copy, nonnull) NSString *term;
@property (nonatomic, copy, nullable) NSString *label;
@property (nonatomic, nullable) NSURL *scheme;

@end

@implementation TPPOPDSCategory

- (nonnull instancetype)initWithTerm:(nonnull NSString *const)term
                               label:(nullable NSString *const)label
                              scheme:(nullable NSURL *const)scheme
{
  if(!term) {
    @throw NSInvalidArgumentException;
  }
  
  self = [super init];
  
  self.term = term;
  self.label = label;
  self.scheme = scheme;
  
  return self;
}

+ (nonnull TPPOPDSCategory *)categoryWithTerm:(nonnull NSString *const)term
                                         label:(nullable NSString *const)label
                                        scheme:(nullable NSURL *const)scheme
{
  return [[TPPOPDSCategory alloc] initWithTerm:term label:label scheme:scheme];
}

@end
