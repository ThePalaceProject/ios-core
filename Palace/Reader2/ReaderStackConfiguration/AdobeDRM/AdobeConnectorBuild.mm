//
//  AdobeConnectorBuild.mm
//  The Palace Project
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#import "AdobeConnectorBuild.h"

#ifdef FEATURE_DRM_CONNECTOR
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreorder"
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wshift-negative-value"
#include "dp_all.h"
#pragma clang diagnostic pop
#endif

// The class is defined in both targets, unlike AdobeDRMContainer, so the test
// bridging header can declare it without the open-source target failing to
// link it.
@implementation AdobeConnectorBuild

+ (NSString *)current {
#ifdef FEATURE_DRM_CONNECTOR
  // The SDK registers its own version strings from a static initializer, so
  // this is readable without starting a DRM workflow or activating a device.
  dp::String build = dp::getVersionInfo("hobbes.build");
  if (build.isNull()) {
    return @"";
  }
  // dp::String is not guaranteed NUL-terminated, so take the length rather
  // than going through stringWithUTF8String:.
  size_t length = 0;
  const unsigned char *bytes = build.data(&length);
  if (bytes == NULL || length == 0) {
    return @"";
  }
  NSString *value = [[NSString alloc] initWithBytes:bytes
                                             length:length
                                           encoding:NSUTF8StringEncoding];
  return value ?: @"";
#else
  // The open-source target links no connector, so there is no build to report.
  return @"";
#endif
}

@end
