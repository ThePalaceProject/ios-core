#import "TPPOPDSType.h"

BOOL TPPOPDSTypeStringIsAcquisition(NSString *const string)
{
  return string != nil && [string rangeOfString:@"acquisition"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;

}

BOOL TPPOPDSTypeStringIsNavigation(NSString *const string)
{
  return string != nil && [string rangeOfString:@"navigation"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;

}

BOOL TPPOPDSTypeStringIsOpenSearchDescription(NSString *string)
{
  return string != nil && [string rangeOfString:@"application/opensearchdescription+xml"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;

}
