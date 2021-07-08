//
//  FAEPersistenceEngine.h
//  AudioEngine
//
//  Created by Alexander Glenn on 2/3/14.
//  Copyright (c) 2015 Findaway. All rights reserved.
//


#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@protocol FAEAudiobookInterface;

/**
 `FAEPersistenceEngine` is a database backed by Core Data that accepts decoded data directly from the AudioEngine API. It operates completely independently from the rest of the SDK, and shares no data with the `DownloadEngine` or `PlaybackEngine`. This makes it an optional component, but may be of use for some integrations.
 #### Availability 
 Since 6.0.0
 */
@interface FAEPersistenceEngine : NSObject

/** @name Singleton
 */

/**
 This returns a handle to the `FAEPersistenceEngine` object.
 
 #### Availability
 Since 6.0.0
 */
+(nullable instancetype)sharedEngine;

/** @name Page Sizes
 */

/**
 The size of the pages that are returned for audiobooks.
 
 #### Availability
 Since 6.0.0
 */
@property long audiobooksPageSize;

/** @name Audiobooks
 */

/**
 Adds an audiobook to the FAEPersistenceEngine from the given dictionary. Returns whether or not the object was added. Duplicates are not allowed.
 
 @param jsonDictionary An audiobook object from the API converted to an NSDictionary by NSJSONSerialization.
 
 #### Availability
 Since 6.0.0
 */
-(BOOL)addAudiobook:(nonnull NSDictionary*)jsonDictionary;

/**
 Returns an Audiobook object for the given audiobookID.
 @param audiobookID
 #### Availability
 Since 6.0.0
 */
-(nullable id<FAEAudiobookInterface>)audiobookForID:(nonnull NSString*)audiobookID;

/**
 Returns an array of audiobook objects matching the supplied NSPredicate, sorted by the supplied sortDescriptors, and in the supplied page. Use audiobooksCount and your supplied page size to determine the page to request starting at page 0.
 
 @param predicate
 @param sortDescriptors
 @param page
 
 #### Availability
 Since 6.0.0
 */
-(nonnull NSArray<id<FAEAudiobookInterface>>*)audiobooksForPredicate:(nullable NSPredicate*)predicate usingSortDescriptors:(nullable NSArray*)sortDescriptors page:(long)pageNumber;

/**
 Returns an array of all stored audiobook ids.
 
 #### Availability
 Since 6.0.0
 */
-(nonnull NSArray*)audiobookIDs;

/**
 Removes an audiobook from the FAEPersistenceEngine from the given audiobookID. Returns whether or not the object was removed.
 
 @param audiobookID
 
 @return BOOL whether or not the audiobook was successfully removed or not
 
 #### Availability
 Since 6.0.0
 */
-(BOOL)removeAudiobookForID:(nonnull NSString*)audiobookID;

/**
 Removes all audiobooks for the FAEPersistenceEngine from the given audiobookID.  Returns whether or not the objects were removed. 
 
 @return BOOL whether or not the audiobooks were all successfully removed or not.
 
 #### Avilability 
 Since 6.1.4
 */

-(BOOL)removeAllAudiobooks; 

/**
 Returns the number of audiobooks in the FAEPersistenceEngine.
 
 #### Availability
 Since 6.0.0
 */
-(long)audiobooksCount;

/**
 Returns the number of audiobooks in the FAEPersistenceEngine for the given predicate.
 
 #### Availability
 Since 6.0.0
 */
-(long)audiobooksCountForPredicate:(nullable NSPredicate*) predicate;

/** @name Database Deletion
 */

/**
 Deletes the database underlying `FAEPersistenceEngine`.
 
 #### Availability
 Since 6.0.0
 */
-(void)deletePersistentStore;

/**
 *  Attempts to create the Core Data Stack from scratch
 */
-(void)setUpStore;

@end
