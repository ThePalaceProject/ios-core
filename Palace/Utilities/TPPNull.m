#import "TPPNull.h"

id TPPNullFromNil(id object)
{
  return object ? object : [NSNull null];
}

id TPPNullToNil(id object)
{
  return [object isKindOfClass:[NSNull class]] ? nil : object;
}
