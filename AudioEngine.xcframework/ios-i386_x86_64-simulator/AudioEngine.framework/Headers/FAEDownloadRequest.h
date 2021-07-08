//
//  AEDownloadRequest.h
//  AudioEngine
//
//  Created by Alex Glenn on 4/21/16.
//  Copyright © 2016 Findaway World. All rights reserved.
//

#import <Foundation/Foundation.h>

extern NSUInteger const FAEDownloadRequestDefaultPart;
extern NSUInteger const FAEDownloadRequestDefaultChapter;

/**
 * This describes the type of download to be performed.
 */
typedef NS_ENUM(NSUInteger, FAEAudiobookDownloadType) {
    /**
     * Download the entire book, starting from any chapter, and wrapping to the beginning.
     */
    FAEAudiobookDownloadTypeFullWrap         = 0,
    /**
     * Download the entire book, starting from any chapter, and stopping at the last chapter.
     */
    FAEAudiobookDownloadTypeFullNoWrap       = 1,
    /** Download the single chapter.
     */
    FAEAudiobookDownloadTypeSingleChapter    = 2,
    /**
     * Default is AEAudiobookDownloadTypeFullWrap.
     */
    FAEAudiobookDownloadTypeDefault          = FAEAudiobookDownloadTypeFullWrap
};

/**
 #### Availability
 Since 6.0.0
 
 `FAEDownloadRequest` encapsulates all of the parameters of an audiobook download. Please see each parameter below for more details on it's purpose.
 */
@interface FAEDownloadRequest : NSObject

/**
 A Unique identifier for this download request
 */
@property (nonatomic, readonly, nonnull) NSString *requestIdentifier;

/**
   Audiobook Id of the book to be downloaded
 */
@property (nonatomic, readonly, nonnull) NSString *audiobookID;

/**
   Part number of the chapter to start downloading from
 */
@property (nonatomic, readonly) NSUInteger partNumber;

/**
   Chapter number of the chapter to start downloading from
 */
@property (nonatomic, readonly) NSUInteger chapterNumber;

/**
   Type of download that is to be performed. See `FAEAudiobookDownloadType` enum for more info
 */
@property (nonatomic, readonly) FAEAudiobookDownloadType downloadType;

/**
   An active session key of the currently logged in user. Will be used as credentials to communicate
   with the AudioEngine API
 */
@property (nonatomic, readonly, nonnull) NSString *sessionKey;

/**
   The license ID that identifies your ownership of the book that is to be downloaded/streamed. Please
   visit the AudioEngine [API](https://developer.audioengine.io) documentation for more information on how to procure a licenseID for your
   particular integration/buisness model
 */
@property (nonatomic, readonly, nonnull) NSString *licenseID;

/**
   Whether or not to restrict the download to WiFi.
 */
@property (nonatomic, readonly) BOOL restrictToWiFi;

/**
   Creates a new Download request with each of the following paramters
 
   @param audiobookID      - ID of the audiobook
   @param partNumber       - part number of the chapter to start downloading from
   @param chapterNumber    - chapter number of the chapter to start downloading from
   @param downloadType     - type of download to be perfomed
   @param sessionKey       - Credential of the logged in user
   @param licenseID        - License token for this audiobook
   @param restrictToWiFi   - Wifi only or not
 
   @return FAEDownloadRequest
 */
-(nonnull instancetype)initWithAudiobookID:(nonnull NSString*)audiobookID
                                 partNumber:(NSUInteger)partNumber
                              chapterNumber:(NSUInteger)chapterNumber
                               downloadType:(FAEAudiobookDownloadType)downloadType
                                 sessionKey:(nonnull NSString *)sessionKey
                                  licenseID:(nonnull NSString *)licenseID
                             restrictToWiFi:(BOOL)restrictToWiFi;

/**
   Creates a new Download request with each of the following paramters and default part and chapter
 
   @param audiobookID      - ID of the audiobook
   @param downloadType     - type of download to be perfomed
   @param sessionKey       - Credential of the logged in user
   @param licenseID        - License token for this audiobook
   @param restrictToWiFi   - Wifi only or not
 
   @return FAEDownloadRequest
 */
-(nonnull instancetype)initWithAudiobookID:(nonnull NSString*)audiobookID
                               downloadType:(FAEAudiobookDownloadType)downloadType
                                 sessionKey:(nonnull NSString *)sessionKey
                                  licenseID:(nonnull NSString *)licenseID
                             restrictToWiFi:(BOOL)restrictToWiFi;

@end
