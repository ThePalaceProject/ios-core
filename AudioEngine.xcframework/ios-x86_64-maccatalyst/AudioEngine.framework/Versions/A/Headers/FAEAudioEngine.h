//
//  FAEAudioEngine.h
//  FAEAudioEngine
//
//  Created by Alexander Glenn on 12/19/13.
//  Copyright (c) 2015 Findaway. All rights reserved.
//
#import <Foundation/Foundation.h>

@class FAEDownloadEngine;
@class FAEPlaybackEngine;

/**
 #### Availability
 Since 6.0.0
 
 `FAEAudioEngine` is the the top level object for managing the FAEAudioEngine SDK's lifecycle. It provides singleton access to `DownloadEngine` and `PlaybackEngine` instances. It also serves as the initialization point for the SDK.
 
 #### Required Method Calls and Notifications
 In order for the SDK to function, it needs to be informed of application life cycle events. These methods should be called in the corresponding methods of the application delegate. `[FAEAudioEngine didFinishLaunching]` must be called in order for FAEAudioEngine to initialize its database and verify its state. When it has completed this task, it will post a notification using the name constant `FAEDatabaseVerificationCompleteNotification`. Do not make any calls to any `DownloadEngine` `PlaybackEngine` methods until this notificaion has fired. Behavior of method calls on any of these methods before this notification is posted are undefined, and may lead to innacurate results and/or exceptions being thrown.
 */

@interface FAEAudioEngine : NSObject {}

/** @name Initialization
 */

/**
 Returns a pointer to a shared instance of audioEngine. If one does not exist, one is created with an empty SessionKey.
 @see sessionKey for adding the session key
 #### Availability
 Since 6.0.0
 */
+(nullable instancetype)sharedEngine;

/** @name Life Cycle Management
 */

/**
 Must be called in [AppDelegate -application:didFinishLaunchingWithOptions:] on the main thread. Notifies FAEAudioEngine that the application has finished launching. FAEAudioEngine will initilize its database and perform an integrity check on the data contained within by comparing with the filesystem. After this method is called, FAEAudioEngine will post a notification using the name constant `FAEDatabaseVerificationCompleteNotification`. Behavior of method calls on any SDK method before this notification is posted are undefined, and may lead to innacurate results and/or exceptions being thrown.
 
 #### Availability
 Since 6.0.0
 */
-(void)didFinishLaunching;

/**
 Must be called in [AppDelegate -applicationDidEnterBackground:]. Notifies FAEAudioEngine that the application is entering the background. FAEAudioEngine will make sure that all data is saved and that playback and downloads will continue.
 #### Availability
 Since 6.0.0
 */
-(void)didEnterBackground;

/**
 Must be called in [AppDelegate -applicationWillTerminate:]. Notifies FAEAudioEngine that the application is being terminated. FAEAudioEngine will make sure all data is saved and that playback is cleaned up and stopped.
 #### Availability
 Since 6.0.0
 */
-(void)willTerminate;

/** @name Downloading and Playing
 */

/**
 An initialized `DownloadEngine` instance. Starts and manages all audio file downloads. @see `DownloadEngine` for more information.
 #### Availability
 Since 6.0.0
 */
@property (readonly, nullable) FAEDownloadEngine *downloadEngine;

/**
 An initialized `PlaybackEngine` instance. Starts and manages all audio playback from disk and streaming. @see `PlaybackEngine` for more information.
 #### Availability
 Since 6.0.0
 */
@property (readonly, nullable) FAEPlaybackEngine *playbackEngine;

/** @name Version Information
 */

/**
 @return The current version number of the SDK
 #### Availability
 Since 6.0.0
 */
+(nonnull NSString*)currentVersion;


/**
 *  Error domain of errors that originate from the AudioEngine Library
 */
FOUNDATION_EXPORT  NSString * _Nonnull const FAEErrorDomain;


@end
