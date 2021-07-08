//
//  FAEAudiobookInterface.h
//  AudioEngine
//
//  Created by Alex Glenn on 4/17/15.
//  Copyright (c) 2015 Findaway World. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifndef AudioEngine_FAEAudiobookInterface_h
#define AudioEngine_FAEAudiobookInterface_h
@protocol FAEChapterInterface;

/**
 The properties and methods of an audiobook object. Is used for `FAEAudiobook` in the `PersistenceEngine`, but could be applied to a custom object and stored in another database, or just used in memory if convenient.
 #### Availability
 Since 6.0.0
 */
@protocol FAEAudiobookInterface <NSObject>

/**
 The audiobook's id number.
 #### Availability
 Since 6.0.0
  */
@property (nonatomic, retain, nonnull) NSString * audiobookID;

/**
 The abridgement of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * abridgement;

/**
 The size in bytes of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSNumber * actualSize;

/**
 The publisher's description of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * audiobookDescription;

/**
 The author of the book.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSArray * authors;

/**
 The awards that the audiobook has won.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSArray * awards;

/**
 Whether or not the book is chapterized (BOOL).
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSNumber * chapterized;

/**
 The copyright information for the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * copyright;

/**
 The url for the cover image of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * coverURL;

/**
 The grade level of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * gradeLevel;

/**
 The library ISBN of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * isbnLibrary;

/**
 The retail ISBN of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * isbnRetail;

/**
 The language of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * language;

/**
 A string that is recalculated when the audiobook's metadata is updated.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * metadataSig;

/**
 The date the audiobook's metadata was last updated.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSDate * modifiedDate;

/**
 The narrator of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSArray * narrators;

/**
 The publisher of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * publisher;

/**
 The runtime in seconds of the audiobook (long long).
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * runtime;

/**
 The url of a sample of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * sampleURL;

/**
 The series that the audiobook belongs to.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSArray * series;

/**
 The release date of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSDate * streetDate;

/**
 The subTitle of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * subTitle;

/**
 The title of the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSString * title;

/**
 The set of chapters in the audiobook.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSSet<id<FAEChapterInterface>> *chapters;

/**
 String of bisac codes
 #### Availability
 Since 6.0
 */
@property (nonatomic, retain, nonnull) NSArray * bisacCodes;

/**
 Returns a single Chapter object for the given part and chapter.
 
 @param part The part number of the chapter to be returned, if it exists.
 @param chapter The chapter number of the chapter to be returned, if it exists.
 
 @retrun The specified chapter, if it exists.
 
 #### Availability
 Since 6.0.0
 */
-(nullable id<FAEChapterInterface>)chapterForPartNumber:(int)partNumber chapterNumber:(int)chapterNumber;

/**
 Returns an array of chapters sorted in their playback order.
 #### Availability
 Since 6.0.0
 */
-(nonnull NSArray<id<FAEChapterInterface>>*)sortedChapters;

@end

#endif
