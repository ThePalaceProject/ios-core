//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "Palace-Bridging-Header.h"
#import "TPPOpenSearchDescription.h"
#import "NSString+TPPStringAdditions.h"

#import "ADEPT/NYPLADEPTErrors.h"
#import "ADEPT/NYPLADEPT.h"
#import "ADEPT/ADEPT.h"
#import "AdobeDRMContainer.h"

//
// Override here any ObjC declarations to facilitate testing
//

@interface TPPOpenSearchDescription ()
@property (nonatomic, readwrite, nullable) NSString *OPDSURLTemplate;
@end

@interface UIColor ()
- (nullable NSString *)javascriptHexString;
@end
