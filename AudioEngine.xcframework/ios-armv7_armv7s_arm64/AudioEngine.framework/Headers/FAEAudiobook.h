//
//  FAEAudiobook.h
//  AudioEngine
//
//  Created by Alexander Glenn on 2/3/14.
//  Copyright (c) 2015 Findaway. All rights reserved.
//

#import "FAEAudiobookInterface.h"
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class  FAEChapter;

/**
 The representation of an audiobook.
 #### Availability 
 Since 6.0.0
 */
@interface FAEAudiobook : NSManagedObject <FAEAudiobookInterface>

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
@property (nonatomic, retain, nonnull) NSSet *chapters;

/**
 String of bisac codes
 #### Availability
 Since 6.0
 */
@property (nonatomic, retain, nonnull) NSArray * bisacCodes;

/**
 Returns a chapter object given the partNumber and chapterNumber supplied, if it exists.
 
 @param partNumber The part number of the chapter to be returned.
 @param chapterNumber The chapter number of the chapter to be returned.
 
 @return The specified chapter, if it exists. 'nil' otherwise.
 
 #### Availability
 Since 6.0.0
 */
-(nullable FAEChapter *)chapterForPartNumber:(int)partNumber chapterNumber:(int)chapterNumber;

/**
 Returns an array of chapters sorted in their playback order.
 #### Availability
 Since 6.0.0
 */
-(nonnull NSArray*)sortedChapters;

@end
