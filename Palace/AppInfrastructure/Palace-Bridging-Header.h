#if FEATURE_DRM_CONNECTOR
#import "ADEPT/NYPLADEPTErrors.h"
#import "ADEPT/NYPLADEPT.h"
#import "ADEPT/ADEPT.h"
#import "AdobeDRMContainer.h"
#import "RDServicesStubs.h"
#endif

#if FEATURE_OVERDRIVE
#import "OverdriveProcessor/OverdriveProcessor.h"
#endif

// NYPLTenPrintCoverView.h transitively imports <CoreText/CoreText.h> and
// <UIKit/UIKit.h>. Under Clang modules those become @import statements,
// which fail in Objective-C++ (.mm) compilation contexts where C++ modules
// are disabled. Swift compiles the bridging header in pure Objective-C
// mode (where this is fine), so guarding on !__cplusplus skips it for the
// ObjC++ consumers (e.g. AdobeDRMContainer.mm) without affecting Swift.
#if !defined(__cplusplus)
#import "NYPLTenPrintCoverView.h"
#endif
#import "../Utilities/TPPObjCExceptionCatcher.h"
