//
//  FAEChapterInterface.h
//  AudioEngine
//
//  Created by Alex Glenn on 4/17/15.
//  Copyright (c) 2015 Findaway World. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifndef AudioEngine_FAEChapterInterface_h
#define AudioEngine_FAEChapterInterface_h

/**
 The properties of a chapter object. Is used for `FAEChapter` in the `PersistenceEngine`, but could be applied to a custom object and stored in another database, or just used in memory if convenient.
 #### Availability 
 Since 6.0.0
 */
@protocol FAEChapterInterface <NSObject>

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
#endif
