//
//  ChapterDescriptor.h
//  AudioEngine
//
//  Created by Alex Glenn on 2/3/15.
//  Copyright (c) 2015 Findaway World. All rights reserved.
//

#import <Foundation/Foundation.h>

/**
 Represents a chapter of an audiobook.
 
 #### Availability
 Since 4.0.0
 
 */
@interface FAEChapterDescription : NSObject <NSCopying>

/**
 The ID of the audiobook to which the chapter belongs.
 */
@property (nonnull) NSString *audiobookID;
/**
 The part number of the chapter.
 */
@property NSUInteger partNumber;
/**
 The chapter number within the part of the chapter.
 */
@property NSUInteger chapterNumber;

/**
 #### Availability
 Since 6.0.0
 Creates a new Chapter Description with the following parameters
 
 @param audiobookID   - Id of the audiobook
 @param partNumber    - part numer of the chapter
 @param chapterNumber - chapter number of the chapter
 
 @return FAEChapterDescription
*/
-(nullable instancetype)initWithAudiobookID:(nonnull NSString*)audiobookID partNumber:(NSUInteger)partNumber chapterNumber:(NSUInteger)chapterNumber;

/**
 #### Availability
 Since 6.0.0

 Creates a new Chapter Description by parsing the given string.

 @note string must be in the format audiobookid_part_chapter ( i.e. 44356_1_2 )

 @param string - formatted string to be parsed

 @return FAEChapterDescription
 */
-(nullable instancetype)initWithString:(nonnull NSString*)string;


/**
 #### Availability
 Since 6.0.0
 
 Serializes the object to string form.
 
 @return string in the format of audibookid_part_chapter ( i.e. 444356_1_2 )
 */
-(nullable NSString*)toString;


@end
