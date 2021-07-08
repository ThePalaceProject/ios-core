//
//  FAENotifications.h
//  AudioEngine
//
//  Created by Alex Glenn on 3/2/15.
//  Copyright (c) 2015 Findaway World. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifndef AudioEngine_FAENotifications_h
#define AudioEngine_FAENotifications_h

/** @name AudioEngine Notification UserInfo Keys
 */

/**
 The key for an audiobook ID in a notifcation's user info
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookIDUserInfoKey;

/**
 The key for a chapter description in a notifcation's user info
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEChapterDescriptionUserInfoKey;

/**
 The key for an download request ID in a notifcation's user info
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadRequestIDUserInfoKey;

/**
 The key for an Audio Engine Error in a notifcation's user info
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudioEngineErrorUserInfoKey;

/**
 The key for the playback unload reason in a notifcation's user info
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackUnloadedReasonUserInfoKey;

/**
 The key for the listen event that failed to be recorded because of invalid data
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEFailedListenEventUserInfoKey;

/**
 The key for the event that audio was paused in the notification's user info
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterPausedUserInfoKey;

/**
 The key for the playback started listen event that indicates if the events are being streamed or not in the notification's user info
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackStreamingUserInfoKey;

/**
The key for the playback progress update event that indicates the current playback offset in the notification's user info
*/
FOUNDATION_EXPORT NSString* _Nonnull const FAECurrentOfsetUserInfoKey;

/**
The key for the playback notification  that indicates the current playback rate in the notification's user info
*/
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackCurrentRateUserInfoKey;

/** @name AudioEngine Notifications
 */

/**
 Posted when `AudioEngine` has finished initilizing and verifying its database. All AudioEngine SDK methods may be called after this point.
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDatabaseVerificationCompleteNotification;


/** @name DownloadEngine Notifications
 */

/**
 Posted when `DownloadEngine` completed the request passed into: `[DownloadEngine startDownloadWithRequest:]`
 
 @note this will notification be posted asynchonrously with regards to the `[DownloadEngine startDownloadWithRequest:]` method.
 
 Notification userInfo dictionary:
 
 {
    FAEDownloadRequestIDUserInfoKey:<NSString>,
    FAEAudiobookIDUserInfoKey:<NSString>
 }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadRequestSuccessNotification;

/**
 Posted when `DownloadEngine` has failed to download all of the audio data for a download request. See `DownloadFailureCode`.
 Notification userInfo Dictionary:
 
 {
    FAEDownloadRequestIDUserInfoKey: <NSString>,
    FAEAudiobookIDUserInfoKey:<NSString>,
    FAEAudioEngineErrorUserInfoKey:<NSError>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadRequestFailedNotification;

/**
 Posted when `DownloadEngine` has paused the download of an audiobook as a result of a call to `[DownloadEngine pauseForAudiobookID:]`.
 
 @note This will be posted asyncronously of a call to this method, and after `DownloadEngine` has retreived audiobook metadata from the API.
 
 Notification userInfo dictionary:
 
 {
    FAEDownloadRequestIDUserInfoKey:<NSString>,
    FAEAudiobookIDUserInfoKey:<NSString>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadRequestPausedNotification;

/**
 Posted when `DownloadEngine` has cancelled a chapter's download as a result of calls to methods: `[DownloadEngine pauseForAudiobookID:]`, `[DownloadEngine cancelForAudiobookID:partNumber:chapterNumber:]`, `[DownloadEngine cancelForAudiobookID:]`, or `[DownloadEngine cancelAll]` or because of a download failure
 
 Notification userInfo Dictionary:
 
 {
    FAEDownloadRequestIDUserInfoKey:<NSString>,
    FAEAudiobookIDUserInfoKey:<NSString>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadRequestCancelledNotification;


/**
 Posted when `DownloadEngine` has staged the download data for an audiobook as a result of calling:
    `[DownloadEngine startDownloadWithRequest:]`
 
 @note this will notification be posted asynchonrously with regards to the `[DownloadEngine startDownloadWithRequest:]` method.
 
 Notification userInfo dictionary:
 
    {
        FAEDownloadRequestIDUserInfoKey:<NSString>,
        FAEAudiobookIDUserInfoKey: <NSString>
    }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookDownloadStagedNotification;

/**
 Posted when `DownloadEngine` has started to download data for an audiobook as a result of calls to methods: `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:]` or `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:ignoreWifi:]`. 
 
 @note This will be posted asyncronously of a call to either of these methods, and after `DownloadEngine` has retreived audiobook metadata from the API.
 
 Notification userInfo dictionary:
 
     {
         FAEDownloadRequestIDUserInfoKey:<NSString>,
         FAEAudiobookIDUserInfoKey:<NSString>
     }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookDownloadStartedNotification;

/**
 Posted when `DownloadEngine` has completed the download of audio data for an entire audiobook as a result of calls to methods: `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:]` or `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:ignoreWifi:]`. 
 
 @note This will be posted asyncronously of a call to either of these methods, and after several chapter releated notifications have been posted @see `FAEChapterDownloadStagedNotification`, `FAEChapterDownloadStartedNotification` and `FAEChapterDownloadSuccessNotification`.
 
Notification userInfo dictionary:

    {
        FAEDownloadRequestIDUserInfoKey:<NSString>,
        FAEAudiobookIDUserInfoKey:<NSString>
    }

 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookDownloadSuccessNotification;


/**
 Posted when `DownloadEngine` has finished deleting all of the audio data for an audiobook as a result of calls to `[DownloadEngine deleteForAudiobookID:]`, `[DownloadEngine deleteAll]`, `[DownloadEngine cancelForAudiobookID:]`, or `[DownloadEngine cancelAll]`. 
 
 @note This will be posted asyncronously of a call to either of these methods.
 
 Notification userInfo dictionary:
 
     {
         FAEAudiobookIDUserInfoKey:<NSString>
     }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookDeleteSuccessNotification;

/**
 Posted when `DownloadEngine` has scheduled a download for a chapter of an audiobook as a result of calls to methods: `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:]` or `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:ignoreWifi:]`. 
 
 @note This will be posted asyncronously of a call to either of these methods, and after `DownloadEngine` has retreived audiobook metadata from the API.

Notification userInfo dictionary:

    {
        FAEDownloadRequestIDUserInfoKey:<NSString>,
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>
    }

 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEChapterDownloadStagedNotification;

/**
 Posted when `DownloadEngine` has started to download data for a chapter of an audiobook as a result of calls to methods: `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:]` or `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:ignoreWifi:]`. 
 
 @note this will be posted asyncronously of a call to either of these methods, and after `DownloadEngine` has retreived audiobook metadata from the API.

Notification userInfo Dictionary:

    {
        FAEDownloadRequestIDUserInfoKey:<NSString>,
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>
    }

 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEChapterDownloadStartedNotification;

/**
 Posted when `DownloadEngine` has completed the download of audio data for a chapter of an audiobook as a result of calls to methods: `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:]` or `[DownloadEngine startDownloadForAudiobookID:partNumber:chapterNumber:continueForBook:wrapToBeginning:accountID:checkoutID:ignoreWifi:]`. 
 
 @note This will be posted asyncronously of a call to either of these methods, and after `DownloadEngine` has retreived audiobook metadata from the API.

Notification userInfo Dictionary:

    {
        FAEDownloadRequestIDUserInfoKey:<NSString>,
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>
    }

 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEChapterDownloadSuccessNotification;


/**
 Posted when `DownloadEngine` has failed to download the audio data for a chapter of an audiobook. See `DownloadFailureCode`.

Notification userInfo Dictionary:

    {
        FAEDownloadRequestIDUserInfoKey:<NSString>,
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>,
        FAEAudioEngineErrorUserInfoKey:<NSError>
    }

 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEChapterDownloadFailedNotification;

/**
 Posted when `DownloadEngine` has finished deleting the audio data for a chapter of an audiobook as a result of a call to `[DownloadEngine deleteForAudiobookID:partNumber:chapterNumber:]` 
 
 @note this will be posted asyncronously of a call to this method.

Notification userInfo Dictionary:

    {
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>
    }

 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEChapterDeleteSuccessNotification;

/** @name PlaybackEngine Notifications
 */

/**
 Posted when `PlaybackEngine` loads a new chapter to be played back as a result of a call to `[PlaybackEngine playForAudiobookIDpartNumber:chapterNumber:offset:accountID:checkoutID:]`, `[PlaybackEngine nextChapter]`, or `[PlaybackEngine perviousChapter]`. If a book has more than one chapter, multiple `FAEPlaybackChapterLoadedNotification` will be posted. A notification is posted for each chapter as soon as the previous chapter has finished.
 
 @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
 {
    FAEChapterDescriptionUserInfoKey:<ChapterDescription>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterLoadedNotification;

/**
 Posted when `PlaybackEngine` needs to stream a chapter that has been requested for playback because it is not fully downloaded. Posted as a result of a call to `[PlaybackEngine playForAudiobookIDpartNumber:chapterNumber:offset:accountID:checkoutID:]`, `[PlaybackEngine nextChapter]`, or `[PlaybackEngine perviousChapter]`. If a book has more than one chapter not downloaded, `FAEPlaybackStreamingRequestStartedNotification` will be posted only once, as all of the streaming URLs required are fetched in the same network operation. Since this is the case, this notification cannot be used as the method to determine whether or not a chapter (other than the first one to stream) is streaming, only as an indicator that playback will take a few more moments to initiate. See `[PlaybackEngine isStreaming]` to determine streaming vs downloaded playback once `FAEPlaybackChapterStartedNotification` has been posted.
 
 @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
     {
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>
     }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackStreamingRequestStartedNotification;

/**
 Posted when the current offset of the `PlaybackEngine` changes.
 
 @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
     {
        FAEPlaybackCurrentOffsetUserInfoKey:<NSNumber>
     }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackProgressUpdateNotification;


/**
 Posted when `PlaybackEngine` begins playback of a chapter that has been previously loaded (See `FAEPlaybackChapterLoadedNotification`). Posted as a result of a call to `[PlaybackEngine playForAudiobookIDpartNumber:chapterNumber:offset:accountID:checkoutID:]`, `[PlaybackEngine nextChapter]`, or `[PlaybackEngine perviousChapter]`. If a book has more than one chapter, multiple `FAEPlaybackChapterStartedNotification` will be posted.
 
 @note This will be posted synchronously during a call to the `[PlaybackEngine playForAudiobookIDpartNumber:chapterNumber:offset:accountID:checkoutID:]` method for the first chapter, but asyncronously to any other chapters or methods.
 
 Notification userInfo Dictionary:
 
     {
         FAEChapterDescriptionUserInfoKey:<ChapterDescription>
     }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterStartedNotification;

/**
 Posted when `PlaybackEngine` has failed to play a chapter. See `PlaybackFailureCode` for more details.
 
 @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
     {
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>,
        FAEAudioEngineErrorUserInfoKey:<NSError>
     }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterFailedNotification;

/**
 Posted when `PlaybackEngine` has completed playback of a chapter that has been previously started (See `FAEPlaybackChapterStartedNotification`). Posted as a result of a call to `[PlaybackEngine playForAudiobookIDpartNumber:chapterNumber:offset:accountID:checkoutID:]`, `[PlaybackEngine nextChapter]`, or `[PlaybackEngine perviousChapter]`. If a book has more than one chapter, multiple `FAEPlaybackChapterCompleteNotification` will be posted.
 
 @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
     {
         FAEChapterDescriptionUserInfoKey:<ChapterDescription>
     }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterCompleteNotification;

/**
 Posted when `PlaybackEngine` has completed playback of an entire audiobook. Posted as a result of a call to `[PlaybackEngine playForAudiobookIDpartNumber:chapterNumber:offset:accountID:checkoutID:]`.
 
  @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
    {
         FAEAudiobookIDUserInfoKey:<NSString>
    }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackAudiobookCompleteNotification;

/**
 Posted when `PlaybackEngine` has begun preparing for playback after loading the metadata (`FAEPlaybackChapterLoadedNotification`) or when playback has stalled while streaming, and the player needs to catch up.
 
 @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
     {
         FAEChapterDescriptionUserInfoKey:<ChapterDescription>
     }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackBufferingStartNotification;

/**
 Posted when `PlaybackEngine` has finished buffering, resolving the cause of a previous posting of `FAEPlaybackBufferingStartNotification`. Will always be followed by a posting of `FAEPlaybackChapterStartedNotification`.
 
 @note This will be posted asyncronously to a call to any method.
 
 Notification userInfo Dictionary:
 
    {
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>
    }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackBufferingEndNotification;

/**
 Posted when `PlaybackEngine` completes setting the chapter offset.  Will be posted as a result of a call to `[PlaybackEngine setCurrentOffset]` after operation completion.
 
 Notification userInfo Dictionary:
    {
        FAEChapterDescriptionUserInfoKey:<ChapterDescription>
    }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterOffsetCompletedNotification;

/**
 Posted when `PlaybackEngine` completes setting the playback rate.  Will be posted as a result of a call to `[PlaybackEngine setCurrentRate]` after operation completion.
 
 Notification userInfo Dictionary:
    {
        FAEPlaybackCurrentRateUserInfoKey:<NSNumber>
    }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackRateCompletedNotification;

/**
 Posted when `PlaybackEngine` pauses audio playback for any reason. Will be posted as a result of a call to `[PlaybackEngine pause]`, or an interruption caused by another app playing audio, or the current audio route becoming unavailable (headphones being unplugged).
 
 Notification userInfo Dictionary:
 
     {
         FAEChapterDescriptionUserInfoKey:<ChapterDescription>
     }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterPausedNotification;

/**
 Posted when `PlaybackEngine` fails to pause audio playback. Will be posted as a result of a call to `[PlaybackEngine pause]` when the pause could not be performed because the underlying audio player does not exist or is not currently playing
 
 Notification userInfo Dictionary:
 
     {
         FAEChapterDescriptionUserInfoKey:<ChapterDescription>
     }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackChapterPausedFailedNotification;


/**
 Posted when `PlaybackEngine` removes the currently loaded audiobook chapter. Posted as a result of a call to `[PlaybackEngine unload]`, `[PlaybackEngine playForAudiobookIDpartNumber:chapterNumber:offset:accountID:checkoutID:]`, or due to a playback failure.
 
 Notification userInfo Dictionary:
 
 {
    FAEPlaybackUnloadedReasonUserInfoKey:<AEUnloadReasonKey>
 }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEPlaybackAudiobookUnloadedNotification;

/**
 Posted when a failure occurs when reporting a listen event. This is due to an error in the SDK
 Notification userInfo Dictionary:
 
 {
    FAEFailedListenEventUserInfoKey:<NSString>
 }
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEListenEventFailureNotification;

/** @name Deprecated Notifications
 */

/**
 Deprecated. Will be removed in a future version. See `FAEDownloadRequestFailed`. Posted when `DownloadEngine` has failed to download all of the audio data for an download request. See `DownloadFailureCode`.
 Notification userInfo Dictionary:
 
 {
    FAEDownloadRequestIDUserInfoKey:<NSString>,
    FAEAudiobookIDUserInfoKey:<NSString>,
    FAEAudioEngineErrorUserInfoKey:<NSError>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookDownloadFailedNotification;

/**
 Deprecated. Will be removed in a future version. Posted when `DownloadEngine` has cancelled a chapter's download as a result of calls to methods: `[DownloadEngine pauseForAudiobookID:]`, `[DownloadEngine cancelForAudiobookID:partNumber:chapterNumber:]`, `[DownloadEngine cancelForAudiobookID:]`, or `[DownloadEngine cancelAll]` or because of a download failure
 
 Notification userInfo Dictionary:
 {
    FAEChapterDescriptionUserInfoKey:<ChapterDescription>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEChapterDownloadCancelledNotification;

/**
 Deprecated. Will be removed in a future version. Posted when `DownloadEngine` has cancelled an audiobook download as a result of calls to methods: `[DownloadEngine pauseForAudiobookID:]`, `[DownloadEngine cancelForAudiobookID:partNumber:chapterNumber:]`, `[DownloadEngine cancelForAudiobookID:]` or because of a download failure.
 
 Notification userInfo Dictionary:
 
 {
    FAEAudiobookIDUserInfoKey:<NSString>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookDownloadCancelledNotification;

/**
 Deprecated. Will be removed in a future version. Posted when `DownloadEngine` has paused the download of an audiobook as a result of a call to `[DownloadEngine pauseForAudiobookID:]`.
 
 @note This will be posted asyncronously of a call to this method, and after `DownloadEngine` has retreived audiobook metadata from the API.
 
 Notification userInfo dictionary:
 
 {
    FAEAudiobookIDUserInfoKey:<NSString>
 }
 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEAudiobookDownloadPausedNotification;

#endif
