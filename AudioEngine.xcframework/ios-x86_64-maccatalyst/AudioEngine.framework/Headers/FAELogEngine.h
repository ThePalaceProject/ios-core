//
//  LogEngine.h
//  FindawayServices
//
//  Created by Alexander Glenn on 12/20/13.
//  Copyright (c) 2015 Findaway. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <os/log.h>

/**
 The log level that `LogEngine` outputs. Higher levels correspond to more output.
 */
typedef NS_ENUM(NSUInteger, FAELogEngineLevel)
{
    /** No log messages will be outputted */
    FAELogEngineLevelNone         = 0,
    /** Only log messages describing errors will be outputted */
    FAELogEngineLevelError        = 1,
    /** Only log messages describing warnings of potentially unintended behavior and errors will be outputted */
    FAELogEngineLevelWarning      = 2,
    /** Only log messages describing general operating information, warnings of potentially unintended behavior, and errors will be outputted */
    FAELogEngineLevelInfo         = 3,
    /** All log messages will be outputted. This includes debugging messages, method calls and returns, as well as the lower log level's messages */
    FAELogEngineLevelVerbose      = 4,
};

/**
 `LogEngine` is the logging system used internally by the SDK. It uses NSLog on iOS 9 and below, and OSLog on iOS 10+.
 
 #### Availability 
 Since 6.0.0 
 */
@interface FAELogEngine : NSObject

/** @name Log Level
 */

/**
 Returns the SDK's current log level.
 
 #### Availability
 Since 6.0.0
 #### Deprecated
 Since 6.2.0
 */
+(int)currentLogLevel __deprecated_msg("Will be removed in a future version. On iOS 10+, log level is goverened by OSLog");

/**
 Sets the SDK's log level. Any LogEngine statements encountered in the SDK will now conform to the log level.
 
 #### Availability
 Since 6.0.0
 #### Deprecated
 Since 6.2.0
 */
+(void)setLogLevel:(FAELogEngineLevel)logLevel __deprecated_msg("Will be removed in a future version. On iOS 10+, log level is goverened by OSLog");
@end

/**
 LogEngine Log Functions
 */

/**
 Logs to the console and disk if the log level is `LogEngineLevelError` or higher.
 
 #### Availability
 Since 6.0.0
 */
void LogEngineError(NSString* _Nonnull format, ...);

/**
 Logs to the console and disk if the log level is `LogEngineLevelWarning` or higher.
 
 #### Availability
 Since 6.0.0
 */
void LogEngineWarning(NSString* _Nonnull format, ...);

/**
 Logs to the console and disk if the log level is `LogEngineLevelInfo` or higher.
 
 #### Availability
 Since 6.0.0
 */
void LogEngineInfo(NSString* _Nonnull format, ...);

/**
 Logs to the console and disk if the log level is `LogEngineLevelVerbose`.
 
 #### Availability
 Since 6.0.0
 */
void LogEngineVerbose(NSString* _Nonnull format, ...);
