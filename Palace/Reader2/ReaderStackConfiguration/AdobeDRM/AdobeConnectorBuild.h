//
//  AdobeConnectorBuild.h
//  The Palace Project
//
//  Reads the Adobe RMSDK build number out of the SDK's own version table so
//  the hand-assigned `AdobeConnectorGeneration.current` has something
//  checkable to be validated against (PP-5251).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#ifndef AdobeConnectorBuild_h
#define AdobeConnectorBuild_h

#import <Foundation/Foundation.h>

@interface AdobeConnectorBuild : NSObject
/// `hobbes.build` from the linked SDK, e.g. `187526`. Empty when the SDK has
/// registered no build number, which is a build-configuration fault rather
/// than a state a patron can reach.
@property (class, nonatomic, readonly, nonnull) NSString *current;
@end

#endif /* AdobeConnectorBuild_h */
