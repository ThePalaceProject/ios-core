//
//  FAEPlaybackEngine.h
//  FAEPlaybackEngine
//
//  Created by Alexander Glenn on 12/19/13.
//  Copyright (c) 2013 Findaway World. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "FAEChapterDescription.h"

/**
 The status of the player
 #### Availability
 Since 6.0.0
 */
typedef NS_ENUM(NSUInteger, FAEPlayerStatus)
{
    /** The player is loaded and playing. */
    FAEPlayerStatusPlaying     = 0,
    /** The player is loaded and not playing. */
    FAEPlayerStatusPaused      = 1,
    /** The player is not loaded and not playing. */
    FAEPlayerStatusUnloaded    = 2,
    /** The player is in progress of becoming loaded and is not playing. */
    FAEPlayerStatusLoading     = 3,
};

/**
 The reason that the chapter has been unloaded
 #### Availability
 Since 6.0.0
 */
typedef NS_ENUM(NSUInteger, FAEUnloadReason)
{
    /** A new playback request has been given and the currently loaded item needs to be removed. */
    FAEUnloadReasonPlaybackInitialized = 0,
    /** Playback has finished, so the current item is no longer needed. */
    FAEUnloadReasonPlaybackCompleted = 1,
    /** Playback failed, so the current item has been aborted. */
    FAEUnloadReasonPlaybackFailed = 2,
    /** The method `[FAEPlaybackEngine unload]` has been called. */
    FAEUnloadReasonUserRequested = 3,
};

/**
 The reason that the audio has been paused.
 #### Availability
 Since 6.0.0
 */
typedef NS_ENUM(NSUInteger, FAEPlaybackPauseReason)
{
    /** The method `[FAEPlaybackEngine pause]` has been called */
    FAEPlaybackPauseReasonPauseCalled          = 0,
    /** The network was unable to keep up with playback speed, so playback has paused. */
    FAEPlaybackPauseReasonPlaybackStalled      = 1,
    /** Audio has been played somewhere else on the system, and `FAEPlaybackEngine` has stopped in response. */
    FAEPlaybackPauseReasonPlaybackInterruption    = 2,
    /** The output device that was being used is no longer available (headphones removed, most likely). */
    FAEPlaybackPauseReasonAudioRouteChange          = 3,
};


/**
 #### Availability
 Since 6.0.0
 
 `FAEPlaybackEngine` manages the playback of audiobooks. Once playback is started, chapters will be played in order until the entire book is completed. The status of playback can be checked at any time with the `playerStatus` property, and the current chapter is provided by the method `[FAEPlaybackEngine currentLoadedChapter]`. The `FAEPlaybackEngine` also communicates the change of playback status via NSNotifications which are posted through the shared NSNotificationCenter. For more information on notifications, see the [Constants Page](../Constants.html)
 
 @note In the SDK, there is a concept of a "chapter". In AudioEngine, each chapter of an audiobook does not contain a "track number" or "playback order". Instead, chapters are organized as they were in the physical book: separated into several parts, with a collection of chapters therein. To identify a chapter, it is given a "part number" to designate the part of the book that it comes from, and a "chapter number" to designate the index of the chapter within the part. Books are downloaded and played back in part order, with each chapter being downloaded or played in order within the part. For example:
 
 ```
 chapters = [{"partNumber":1, "chapterNumber":1},
         {"partNumber":1, "chapterNumber":2},
         {"partNumber":2, "chapterNumber":1},
         {"partNumber":2, "chapterNumber":2},
         {"partNumber":2, "chapterNumber":3},
         {"partNumber":3, "chapterNumber":1}]; // A Sorted array of chapters
 ```
 
 
 */
@interface FAEPlaybackEngine : NSObject

/** @name Starting Playback
 */

/**
 Loads and starts to play the specified audiobook at the given part, chapter, and offset ( in seconds ) into the chapter for the specified `licenseID`.
 
 When the chapter is verified and loaded, a notification named `FAEPlaybackChapterLoadedNotification` will be posted. 
 
 When the audio starts to play, a notification named `FAEPlaybackChapterStartedNotification` will be posted. 
 
 When a chapter's playback completes, a notification named `FAEPlaybackChapterCompleteNotification` will be posted, and the next chapter will be loaded and begin to play. 
 
 When the entire book has finished playback, a notification named `FAEPlaybackAudiobookCompleteNotification` will be posted.
 
 If there is an erorr starting playback, a notification named `FAEPlaybackChapterFailedNotification` will be posted. 
 
 After the audio is loaded, a notification named `FAEPlaybackBufferingStartNotification` will be posted to designate the time where audio is preparing to play. When the buffering ends, a notification `FAEPlaybackBufferingEndNotification` will be posted. 
 
 To cancel the loading of audio call `[FAEPlaybackEngine unload]`. See the [Constants Page](../Constants.html) for more information.
 
 @param audiobookID     The audiobook ID of the book to be played
 @param partNumber      The first chapter to be played's part number
 @param chapterNumber   The first chapter to be played's chapter number
 @param offset          The offset at which to play the chapter
 @param sessionKey      The sessionKey of the current user
 @param licenseID       The license of the audiobook to be played
 
 #### Availability
 Since 6.0.0
 */
-(void)playForAudiobookID:(nonnull NSString *)audiobookID partNumber:(NSUInteger)partNumber chapterNumber:(NSUInteger)chapterNumber offset:(NSUInteger)offset sessionKey:(nonnull NSString *)sessionKey licenseID:(nonnull NSString *)licenseID;

/** @name Playback Management
 */

/**
 Continues to play the currently loaded content. When audio starts to play, a notification named `FAEPlaybackChapterStartedNotification` will be posted. See the [Constants Page](../Constants.html) for more information.
 
 #### Availability
 Since 6.0.0
 */
-(void)resume;

/**
 Pauses playback of the currently loaded content. When audio is paused, a notification named `FAEPlaybackChapterPausedNotification` will be posted. See the [Constants Page](../Constants.html) for more information.
 
 #### Availability
 Since 6.0.0
 */
-(void)pause;

/**
 Loads and starts to play the next chapter of the currently loaded audiobook. When the chapter is verified and loaded, a notification named `FAEPlaybackChapterLoadedNotification` will be posted. See the [Constants Page](../Constants.html) for more information.
 
 #### Availability
 Since 6.0.0
 */
-(void)nextChapter;

/**
 Loads and starts to play the previous chapter of the currently loaded audiobook. When the chapter is verified and loaded, a notification named `FAEPlaybackChapterLoadedNotification` will be posted. See the [Constants Page](../Constants.html) for more information.
 
 #### Availability
 Since 6.0.0
 */
-(void)previousChapter;

/**
 Unloads the currently loaded content. A notification named `FAEPlaybackChapterUnloadedNotification` will be posted upon completion. There is no userInfo dictionary associated
 with the notification as there is no audiobookID after unloading. See the [Constants Page](../Constants.html) for more information.
 
 #### Availability
 Since 6.0.0
 */
-(void)unload;


/** @name Playback Status Monitoring
 */

/**
 The status of the player. `PlayerStatusPlaying` indicates that playback is currently taking place. `PlayerStatusPaused` indicates that the player has something loaded but is
 currently paused. `PlayerStatusUnloaded` is when the player has no audio ready to play.
 
 #### Availability
 Since 6.0.0
 */
@property (readonly) FAEPlayerStatus playerStatus;


/**
 The currentOffset in seconds.  `FAEPlaybackChapterOffsetCompletedNotification` is posted after offset is successfully set.  
 
 #### Availability
 Since 6.0.0
 */
@property NSUInteger currentOffset;

/**
 The duration of the currently loaded file in seconds.
 
 #### Availability
 Since 6.0.0
 */
@property (readonly) NSUInteger currentDuration;

/**
 The current playback rate multiplier. 1.0 is 100%.
 
 #### Availability
 Since 6.0.0
 */
@property (nonatomic) float currentRate;

/**
 Wheter or not streaming playback is occuring.
 
 #### Availability
 Since 6.0.0
 */
@property (readonly) BOOL isStreaming;

/**
 The current current chapter loaded in the player. See `FAEChapterDescription`
 
 #### Availability
 Since 6.0.0
 */
-(nullable FAEChapterDescription *)currentLoadedChapter;

/**
 A sorted array of all `FAEChapterDescription` objects in the book
 
 #### Availability
 Since 6.0.0
 */
-(nonnull NSArray *)audiobookChapterDescriptions;

/** @name Playback Configuration
 */

/**
 Sets whether or not streams should be restricted to wifi only or not. 
 
 #### Availability
 Since 6.0.0
 
 @note This only affects streaming, and not on disk playback. It also does not affect streaming that has already been started. To immediately halt cellular access, call `[FAEPlaybackEngine unload]` and then start playback again after changing this setting.
  */
@property BOOL wifiOnly;

/**
 The maximum time in seconds that the player will wait once playback has stalled in a poor network situation. Defaults to 10 seconds. After the max stall time has elapsed a notification named `FAEPlaybackChapterFailedNotification` will be posted with error code `PlaybackExtendedStall`.
 
 #### Availability
 Since 6.0.0
 */
@property NSUInteger maxStallTime;


/**
 The possible error codes that can be posted along with `FAEPlaybackChapterFailedNotification`
 */
typedef NS_ENUM(NSUInteger, FAEPlaybackFailureCode)
{
    /** The requested file was not found. The player is configured to halt in this condition. */
    FAEPlaybackFailureCodeFileNotFound = 20000,
    /** The file is not on disk, and no streaming URL could be generated. */
    FAEPlaybackFailureCodeResourceCannotBeLoaded = 20001,
    /** The audiobookID that was requested was not found in the database for playback. */
    FAEPlaybackFailureCodeInvalidAudiobookID = 20002,
    /**  The chapter that was requested to be played was not found in the specified audiobook. */
    FAEPlaybackFailureCodeInvalidChapter = 20003,
    /** The playlist could not be loaded at this time. */
    FAEPlaybackFailureCodePlaylistCannotBeLoaded = 20004,
    /** The playback request failed because there was a server side error. */
    FAEPlaybackFailureCodeServerSideError = 20005,
    /** The playback failed because the licenseID may have been invalid */
    FAEPlaybackFailureCodeInvalidLicenseID = 20006,
    /** The playback failed because a request timed out */
    FAEPlaybackFailureCodeRequestTimedOut = 20007,
    /** The playback failed for an unknown reason, unknown server response received */
    FAEPlaybackFailureCodeUnknownServerResponse = 20008,
    /** Could not fetch the requested audiobook's metadata from AudioEngine. */
    FAEPlaybackFailureCodeMetadataUnavailable = 20009,
    /** The playback request timed out while trying to contact the internal webserver. Recovery was attempted and failed. Network traffic may be restricted. */
    FAEPlaybackFailureCodeUnableToPlayback = 21000,
    /** The playback request failed because the file is not on disk, and preferences limit streaming to WiFi. */
    FAEPlaybackFailureCodeCellularProhibited = 21001,
    /** Something went wrong, the AVPlayerItem status changed to failed. */
    FAEPlaybackFailureCodeAVPlayerItemFailed = 22000,
    /** The AVPlayerItem stalled and did not recover in time. */
    FAEPlaybackFailureCodePlaybackExtendedStall = 22001,
    /** The AVPlayerItem status was switched to unknown after being started. */
    FAEPlaybackFailureCodeAVPlayerStatusUnknownError = 22002,
    /** The AVPlayerItem that was loaded into the player had a failed status. */
    FAEPlaybackFailureCodeAVPlayerEarlyFailure = 22003,
    /* The AVPlayerItem ended before it reached its duration. */
    FAEPlaybackFailureCodeAVPlayerEarlyEnd = 22004,
    /* The queue failed to be filled because the next chapter could not be found */
    FAEPlaybackFailureCodeQueueLoadFailure = 22005,
    /** The AVPlayerItem failed to stream due to being unauthorized. The session or audio key may have expired.*/
    FAEPlaybackFailureCodePlaybackUnauthorized = 23000,
    /** The streaming URLs did not get returned. */
    FAEPlaybackFailureCodeStreamingUnavailable = 24000,
    /** The list of URLS for streaming was returned with an error.*/
    FAEPlaybackFailureCodeStreamingURLError = 24001,
    /** The requested file could not be opened for playback. */
    FAEPlaybackFailureCodeFileOpenFailure = 25000,
    /** The requested file could not be read for playback. */
    FAEPlaybackFailureCodeFileReadFailure = 25001,
    /** The requested data could not be read from the file. */
    FAEPlaybackFailureCodeFileNoDataFailure = 25002,
    /** Could not seek to the required location in the requested file. */
    FAEPlaybackFailureCodeFileSeekFailure = 25003,
    /** Setting the AVAudioSession to active failed. Playback will not continue without it. */
    FAEPlaybackFailureCodeAVAudioSessionActivationFailure = 26000
};

/**
 *  Convienence method used for converting `FAEPlaybackFailureCode` enums into consumanle error strings. The error strings
 *  are defined in the `FAEPlaybackEngine.h` header.
 *
 *  @param code - enum to be converted
 *
 *  @return Consumable error strings
 */
+(nonnull NSString*)descriptionForErrorCode:(FAEPlaybackFailureCode)code;


/**
    Playback Failure - File not found
*/
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureFileNotFoundDescription;
/**
    Playback Failure - resouce cannot be loaded
*/
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureResourceCannotBeLoadedDescription;
/**
    Playback Failure - invalid audiobookID
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureInvalidAudiobookIDDescription;
/**
    Playback Failure - invalid chapter
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureInvalidChapterDescription;
/**
    Playback Failure - The playlist could not be loaded at this time. 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailurePlaylistCannotBeLoaded;
/**
    Playback Failure - Server side error
 */
FOUNDATION_EXPORT NSString *_Nonnull const FAEPlaybackFailureServerSideErrorDescription;
/** 
    Playback Failure - License key was missing or invalid
 */
FOUNDATION_EXPORT NSString *_Nonnull const FAEPlaybackFailureInvalidLicenseIDDescription;
/**
    Playback Failure - Request timed out
 */
FOUNDATION_EXPORT NSString *_Nonnull const FAEPlaybackFailureRequestTimedOutDescription;
/**
    Playback Failure - Unknown server response
 */
FOUNDATION_EXPORT NSString *_Nonnull const FAEPlaybackFailureUnknownServerResponseDescription;
/**
 Playback Failure - Unable to fetch the audiobook's metadata
 */
FOUNDATION_EXPORT NSString *_Nonnull const FAEPlaybackFailureMetadataUnavilableDescription;
/**
    Playback Failure - unable to play
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureUnableToPlaybackDescription;
/**
    Playback Failure - Cellular Prohibited
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureCellularPohibitedDescription;
/**
    Playback Failure - AVPlayer item failed
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureAVPlayerItemFailedDescription;
/**
    Playback Failure - Extended Stall
*/
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailurePlaybackExtendedStallDescription;
/**
    Playback Failure - AVPlayer status unknown error
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureAVPlayerStatusUnknownErrorDescription;
/**
    Playback Failure - AVPlayer Early failure
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureAVPlayerEarlyFailureDescription;
/**
    Playback Failure - AVPlayer early end
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureAVPlayerEarlyEndDescription;
/**
    Playback Failure - Queue load
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureQueueLoadFailureDescription;
/**
    Playback Failure - playback unauthorized
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailurePlaybackUnauthorizedDescription;
/**
    Playback Failure - Streaming unavailable
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureStreamingUnavailableDescription;
/**
    Playback Failure - Streaming URLError
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureStreamingURLErrorDescription;
/**
    Playback Failure - File open Failure
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureFileOpenFailureDescription;
/**
    Playback Failure - File read failure
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureFileReadFailureDescription;
/**
    Playback Failure - File no data failure
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureFileNoDataFailureDescription;
/**
    Playback Failure - File seek failure 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureFileSeekFailureDescription;
/**
    Playback Failure - AVAudio session activiation failure
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureAVAudioSessionActivationFailureDescription;
/**
    Playback Failure - playback failure reason unknown
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackFailureUnknownDescription;

@end
