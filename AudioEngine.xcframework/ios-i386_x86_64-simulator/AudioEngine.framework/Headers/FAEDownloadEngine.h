//
//  FAEDownloadEngine.h
//  FAEDownloadEngine
//
//  Created by Alexander Glenn on 12/19/13.
//  Copyright (c) 2015 Findaway. All rights reserved.
//
#import <Foundation/Foundation.h>

@class FAEDownloadRequest;

/** 
 The status of an audiobook or chapter download.
 */
typedef NS_ENUM(NSUInteger, FAEDownloadStatus)
{
    /** The download has not been started, or has been deleted. */
    FAEDownloadStatusNotDownloaded = 0,
    /** The download is currently in progress. */
    FAEDownloadStatusDownloading = 1,
    /** The download has been started, but is not currently in progress. Not possible for chapters. */
    FAEDownloadStatusDownloadPaused = 2,
    /** The download is complete. */
    FAEDownloadStatusDownloaded = 3,
    /** The download has been scheduled for download, but has not yet begun. */
    FAEDownloadStatusDownloadStaged = 4
};

/**
 #### Availability
 Since 6.0.0
 
 `FAEDownloadEngine` manages the download of audiobooks. Backed by NSURLSession, the `FAEDownloadEngine` is capable of foreground and background downloads. The status of a download can be checked at any time with the -statusForAudiobookID: method. The `FAEDownloadEngine` also communicates the change of an audiobook or chapter's status via NSNotifications which are posted through the shared NSNotificationCenter. For more information on notifications, see the [Constants Page](../Constants.html)
 
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
@interface FAEDownloadEngine : NSObject {}

/** @name Starting a Download
 */

/**
 Starts a download the specified chapter of the specified audiobook. See `FAEDownloadRequest` for more information. If some files have already been downloaded, they are not downloaded again.
 The download will be performed asynchronously, posting NSNotifications to update of its progress. When the download completes, a notification named `FAEDownloadRequestSuccessNotification` will be posted. If an error occurs, a notification named `FAEDownloadRequestFailedNotification` will be posted. See the [Constants Page](../Constants.html) for a full list of notifications.
 
 @param downloadRequest The request to start
 
 #### Availability
 Since 6.0.0
 */
-(void)startDownloadWithRequest:(nonnull FAEDownloadRequest*)downloadRequest;

/** @name Download Management
 */

/**
 Returns all download requests that have been passed to `startDownloadWithRequest:`, but have not yet completed.
 
 @return A list of all active download requests.
 
 #### Availability
 Since 6.1.0
*/
-(nonnull NSArray<FAEDownloadRequest*>*)currentDownloadRequests;

/**
 Asynchronously pauses the specified download request. All complete files are kept on disk. A notification named `FAEDownloadRequestPausedNotification` will be posted when the pause completes. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 @param requestIdentifier The request identifier of the download request to be paused.
 
 #### Availability
 Since 6.1.0
 */
-(void)pauseDownloadForRequestIdentifier:(nonnull NSString*)requestIdentifier;

/**
 Asynchronously pauses all download requests. All complete files are kept on disk. A notification named `FAEDownloadRequestPausedNotification` will be postedfor each request that is paused. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 #### Availability
 Since 6.1.0
 */
-(void)pauseAll;

/**
 Asynchronously cancels the specified download request. All complete and incomplete files are removed. A notification named `FAEChapterDeleteSuccesssNotification` will be fired when the files have been deleted. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 @param requestIdentifier The request identifier of the download request to be cancelled.
 
 #### Availability
 Since 6.1.0
 */
-(void)cancelDownloadForRequestIdentifier:(nonnull NSString*)requestIdentifier;

/**
 Cancels all download requests. All complete and incomplete files are removed. A notification named `FAEAudiobookDeleteSuccesssNotification` will be fired when the files have been deleted for each request. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 #### Availability
 Since 6.0.0
 */
-(void)cancelAll;

/** @name File Management
  */

/**
 Deletes the specified file for the specified audiobook
 A notification named `FAEChapterDeleteSuccesssNotification` will be fired upon completion. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 @param audiobookID The audiobook ID of the book whose chapter is to be deleted.
 @param partNumber The part number of the chapter to be deleted.
 @param chapterNumber The chapter number of the chapter to be deleted.
 
 #### Availability
 Since 6.0.0
 */
-(void)deleteForAudiobookID:(nonnull NSString*)audiobookID partNumber:(NSUInteger)partNumber chapterNumber:(NSUInteger)chapterNumber;

/**
 Deletes all files for the specified audiobook
 A notification named `FAEAudiobookDeleteSuccesssNotification` will be fired upon completion. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 @param audiobookID
 
 #### Availability
 Since 6.0.0
 */
-(void)deleteForAudiobookID:(nonnull NSString*)audiobookID;

/**
 Deletes all files for the all audiobooks
 A notification named `FAEAudiobookDeleteSuccesssNotification` will be fired when the files have been deleted for each audiobook. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 #### Availability
 Since 6.0.0
 */
-(void)deleteAll;

/** @name Download Status Monitoring
 */

/**
 Returns the status of the download for the specified audiobook chapter.
 
 @param audiobookID The audiobook ID of the book whose chapter's download status is requested
 @param partNumber The part number of the chapter whose download status is requested.
 @param chapterNumber The chapter number of the chapter whose download status is requested.
 
 @return The `DownloadStatus` of the specified chapter
 
 #### Availability
 Since 6.0.0
 */
-(FAEDownloadStatus)statusForAudiobookID:(nonnull NSString*)audiobookID partNumber:(NSUInteger)partNumber chapterNumber:(NSUInteger)chapterNumber;

/**
 Returns the status of the download for the specified audiobook.
 
 @param audiobookID The audiobook ID of the book whose download status is requested.
 
 @return The `DownloadStatus` of the specified audiobook
 
 #### Availability
 Since 6.0.0
 */
-(FAEDownloadStatus)statusForAudiobookID:(nonnull NSString*)audiobookID;

/**
 Returns the percentage of the download for the specified audiobook chapter.
 
 @param audiobookID The audiobook ID of the book whose chapter's download percentage is requested
 @param partNumber The part number of the chapter whose download percentage is requested.
 @param chapterNumber The chapter number of the chapter whose download percentage is requested.
 
 @return The percentage as a float (0.0 - 100.0) of the specified audiobook chapter.
 
 #### Availability
 Since 6.0.0
 */
-(float)percentageForAudiobookID:(nonnull NSString*)audiobookID partNumber:(NSUInteger)partNumber chapterNumber:(NSUInteger)chapterNumber;

/**
 Returns the percentage of the download for the specified audiobook.
 
 @param audiobookID The audiobook ID of the book whose download percentage is requested
 
 @return The percentage as a float (0.0 - 100.0) of the specified audiobook
 
 #### Availability
 Since 6.0.0
 */
-(float)percentageForAudiobookID:(nonnull NSString*)audiobookID;

/**
 Returns an array of all the audiobookIDs that AudioEngine has record of locally for the given status. These records are cleaned up as part of database verification on initialization. If an audiobook has a `DownloadStatus` other than `DownloadStatusNotDownloaded` at startup it is kept in the database, all others are removed.
 
 @return An `NSArray` of each audiobook ID as `NSString`s.
 
 #### Availability
 Since 6.3.0
 */
-(nonnull NSArray<NSString*>*)localAudiobookIDsForStatus:(FAEDownloadStatus) status;

/**
 Returns an array of all the audiobookIDs that AudioEngine has record of locally. These records are cleaned up as part of database verification on initialization. If an audiobook has a `DownloadStatus` other than `DownloadStatusNotDownloaded` at startup it is kept in the database, all others are removed.
 
 @return An `NSArray` of each audiobook ID as `NSString`s.
 
 #### Availability
 Since 6.0.0
 */
-(nonnull NSArray<NSString*>*)localAudiobookIDs;


#pragma mark -
#pragma mark NSURLSession Background Methods

/** @name Required Methods for Background Downloads
 */

/**
 The string that AudioEngine prefixes its background URLSession identifiers with. Should be used to determine if a call to `application:handleEventsForBackgroundURLSession:completionHandler` should be routed to AudioEngine.
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEBackgroundDownloadSessionIdentifierPrefix;

/**
 Needs to be called when the application is launched to handle background events. This occurs in the AppDelegate method `-application:handleEventsForBackgroundURLSession:completionHandler:` in order for the `FAEDownloadEngine` to handle the results of the tasks. For Example:
 
```
- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)())completionHandler
{
    if ([identifier rangeOfString:FAEBackgroundDownloadSessionIdentifierPrefix].length > 0) {
        [[AudioEngine sharedEngine].downloadEngine addCompletionHandler: completionHandler forSession: identifier];
    }
    [[AudioEngine sharedEngine] didFinishLaunching];
}
```
 */
- (void)addCompletionHandler:(nonnull void (^)(void))handler forSession:(nonnull NSString *)identifier;

#pragma mark -
#pragma mark Error Codes

/**
 The possible error codes that can be posted along with `FAEDownloadRequestFailedNotification`
 */
typedef NS_ENUM(NSUInteger, FAEDownloadFailureCode)
{
    /** The chapter that was requested to be downloaded was not found in the specified audiobook's metadata, the license key was missing, or the request was already used */
    FAEDownloadFailureCodeInvalidChapterDownloadRequest=11000,
    /** A chapter download in progress attempted to look up a chapter that was not found in the specified audiobook. */
    FAEDownloadFailureCodeUnknownDownloadChapterLookup=11001,
    /** A chapter stream in progress attempted to look up a chapter that was not found in the specified audiobook. */
    FAEDownloadFailureCodeUnknownStreamChapterLookup=11002,
    /** All of the chapters that were requested to be downloaded had a status that is not equal to DownloadStatusNotDownloaded. */
    FAEDownloadFailureCodeChapterAlreadyInProgress=11003,
    /** The audiobookID that was requested was not valid or was not found on the server. */
    FAEDownloadFailureCodeInvalidAudiobookDownloadRequest=11004,
    /** Could not fetch the requested audiobook's metadata from AudioEngine. */
    FAEDownloadFailureCodeMetadataUnavailable=11005,
    /** The session key being used for getting metadata before a download is invalid. */
    FAEDownloadFailureCodeMetadataInvalidSession=11006,
    /** Could not construct a request */
    FAEDownloadFailureCodeCouldNotConstructRequest = 11007,
    /** The download failed due to being unauthorized.*/
    FAEDownloadFailureCodeDownloadUnauthorized = 11008,
    /** The download failed, internal server error */
    FAEDownloadFailureCodeInternalServerError = 11009,
    /** The download failed, request timed out */
    FAEDownloadFailureCodeRequestTimedOut = 11010,
    /** The session key for this download is invalid. */
    FAEDownloadFailureCodeDownloadKeyInvalidSession=12000,
    /** The licenseID for this download is invalid. */
    FAEDownloadFailureCodeInvalidLicenseID=12001,
    /** The checkout ID for this audiobook has expired. */
    FAEDownloadFailureCodeCheckoutIDExpired=12002,
    /** Setup for the download has failed  */
    FAEDownloadFailureCodeSetupFailed = 12003,
    /** The download request failed to save to the database */
    FAEDownloadFailureCodeDownloadRequestFailedSaveToDatabase = 12004,
    /** The audiobook download status failed to save to the database */
    FAEDownloadFailureCodeAudiobookDownloadStatusFailedSaveToDatabase = 12005,
    /** A chapter download status failed to save to the database */
    FAEDownloadFailureCodeChapterDownloadStatusFailedSaveToDatabase = 12006,
    /** The session key for this download is invalid. */
    FAEDownloadFailureCodeDownloadPlaylistInvalidSession=13000,
    /** The server returned an unexpected response when `FAEDownloadEngine` requested a playlist. */
    FAEDownloadFailureCodeDownloadPlaylistBadResponse=13001,
    /** The playlist cannot be loaded */
    FAEDownloadFailureCodeDownloadPlaylistCannotBeLoaded = 13002,
    /** The server returned an unexpected response when `FAEDownloadEngine` requested a key. */
    FAEDownloadFailureCodeDownloadKeyBadResponse=14000,
    /** The server returned an unexpected response when `FAEDownloadEngine` requested a key for streaming. */
    FAEDownloadFailureCodeStreamKeyBadResponse=14001,
    /** The server returned an unexpected response when `FAEDownloadEngine` requested an audio file. */
    FAEDownloadFailureCodeDownloadAudioBadResponse=15000,
    /** Moving the downloaded file a second time (after deleting) failed. */
    FAEDownloadFailureCodeDownloadAudioMoveFailure=15001,
    /** The chapter download in progress was cancelled. */
    FAEDownloadFailureCodeDownloadCancelled=16000,
    /** The JSON from the server failed to serialize. */
    FAEDownloadFailureCodeBadJSON=17000,
    /** The system reported that there was no storage space left on the device */
    FAEDownloadFailureCodeNoSpace=18000,
    /** The download failed for an unknown reason. An underlying system error was logged and returned as well. */
    FAEDownloadFailureCodeUnknown=10000,
    /** The download failed for an unknown reason, unknown server response received */
    FAEDownloadFailureCodeUnknownServerResponse=10001
};

/**
 *  Convienence method used for converting `FAEDownloadFailureCode` enums into consumanle error strings. The error strings
 *  are defined in the `FAEDownloadEngine.h` header.
 *
 *  @param code - enum to be converted
 *
 *  @return Consumable error strings
 */
+(nonnull NSString *)descriptionForErrorCode:(FAEDownloadFailureCode)code;


/**
 Download Failure - Invalid chapter download request
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureInvalidChapterDownloadRequestDescription;
/**
 Download Failure - Unknown download chapter lookup
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureUnknownDownloadChapterLookupDescription;
/**
 Download Failure - unknown stream chapter lookup
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureUnknownStreamChapterLookupDescription;
/**
 Download Failure - chapter already in progress
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureChapterAlreadyInProgressDescription;
/**
 Download Failure - Invalid audiobook download request
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureInvalidAudiobookDownloadRequestDescription;
/**
 Download Failure - metadata unavailable
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureMetadataUnavailableDescription;
/**
 Download Failure - metadata invalid session
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureMetadataInvalidSessionDescription;
/**
 Download Failure - Could not construct a request
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureCouldNotConstructRequestDescription;
/**
 Download Failure - download key invalid session
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadKeyInvalidSessionDescription;
/**
 Download Failure - invalid licenseID
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureInvalidLicenseIDDescription;
/**
 Download Failure - checkout id expired
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureCheckoutIDExpiredDescription;
/**
 Download Failure - no delegate allocated for download
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureSetupFailedDescription;
/**
 Download Failure - the download request failed to save to the database
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadRequestFailedSaveToDatabaseDescription;
/**
 Download Failure - the audiobook download status failed to save to the database
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureAudiobookDownloadStatusFailedSaveToDatabaseDescription;
/**
 Download Failure - a chapter download status failed to save to the database
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureChapterDownloadStatusFailedSaveToDatabaseDescription;
/**
 Download Failure - download playlist invalid session
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadPlaylistInvalidSessionDescription;
/**
 Download Failure - download playlist bad response
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadPlaylistBadResponseDescription;
/** 
 Download Failure - playlist cannot be loaded 
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadPlaylistCannotBeLoadedDescription;
/**
 Download Failure - download key bad response
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadKeyBadResponseDescription;
/**
 Download Failure - stream key bad response
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureStreamKeyBadResponseDescription;
/**
 Download Failure - download audio bad response
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadAudioBadResponseDescription;
/**
 Download Failure - download audio move failure
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadAudioMoveFailureDescription;
/**
 Download Failure - download cancelled
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadCancelledDescription;
/**
 Download Failure - bad JSON
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureBadJSONDescription;
/**
 Download Failure - download failure reason unknown
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureUnknownDescription;
/**
 Download Failure - unauthorized 401 (DownloadFailureCodeDownloadUnauthorized).
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureDownloadUnauthorizedDescription;
/**
 Download Failure - request timed out 500 (DownloadFailureCodeUnableToDownload)
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureInternalServerErrorDescription;
/**
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureRequestTimedOutDescription;
/**
 Download Failure - The download failed for an unknown reason, unknown server response received
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureUnknownServerResponseDescription;
/**
 Download Failure - The download failed because the filesystem is full
 */
FOUNDATION_EXPORT NSString* _Nonnull const FAEDownloadFailureNoSpaceDescription;

#pragma mark -
#pragma mark Deprecated Methods

/**
 Asynchronously pauses all download requests for the specified audiobook. All complete files are kept for future resume. A notification named `FAEAudiobookDownloadPausedNotification` will be posted when the pause completes. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 @param audiobookID The audiobook ID of the book whose download is to be paused.
 
 #### Availability
 Since 6.0.0
 #### Deprecated
 Since 6.1.0
 */
-(void)pauseForAudiobookID:(nonnull NSString*)audiobookID __deprecated_msg("Will be removed in a future version. Use `pauseDownloadForRequestIdentifier:` instead.");

/**
 Asynchronously all single chapter download requests for the specified chapter for the given audiobook ID. All complete and incomplete files are removed. A notification named `FAEChapterDeleteSuccesssNotification` will be fired when the files have been deleted. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 @param audiobookID The audiobook ID of the book whose chapter's download is to be cancelled.
 @param partNumber The part number of the chapter to be cancelled.
 @param chapterNumber The chapter number of the chapter to be cancelled.
 
 #### Availability
 Since 6.0.0
 #### Deprecated
 Since 6.1.0
 */
-(void)cancelForAudiobookID:(nonnull NSString*)audiobookID partNumber:(NSUInteger)partNumber chapterNumber:(NSUInteger)chapterNumber __deprecated_msg("Will be removed in a future version. Use `cancelDownloadForRequestIdentifier:` instead.");

/**
 Asynchronously cancels all download requests for the specified audiobook. All complete and incomplete files are removed. A notification named `FAEAudiobookDeleteSuccesssNotification` will be fired when the files have been deleted. See the [Constants Page](../Constants.html) for more information and a full list of notifications.
 
 @param audiobookID
 
 #### Availability
 Since 6.0.0
 #### Deprecated
 Since 6.1.0
 */
-(void)cancelForAudiobookID:(nonnull NSString*)audiobookID __deprecated_msg("Will be removed in a future version. Use `cancelDownloadForRequestIdentifier:` instead.");


@end
