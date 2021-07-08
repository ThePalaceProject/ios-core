//
//  FAEChapter.h
//  AudioEngine
//
//  Created by Alexander Glenn on 2/3/14.
//  Copyright (c) 2015 Findaway. All rights reserved.
//

#import "FAEChapterInterface.h"
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class FAEAudiobook;

/**
 The representation of an audiobook's chapter.
 #### Availability 
 Since 6.0.0
 */
@interface FAEChapter : NSManagedObject <FAEChapterInterface>

/**
 The chapter number associated with the chapter.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSNumber * chapterNumber;

/**
 The duration of the chapter.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSNumber * duration;

/**
 The part number associated with the chapter.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSNumber * partNumber;

/**
 The audiobook that the chapter belongs to.
 #### Availability
 Since 6.0.0
 */
@property (nonatomic, retain, nonnull) NSObject *audiobook;

@end
