////
////  AdobeDRMContainer.h
////  The Palace Project
////
////  Created by Vladimir Fedorov on 13.05.2020.
////  Copyright © 2020 NYPL Labs. All rights reserved.
////
//
//#ifndef AdobeDRMContainer_h
//#define AdobeDRMContainer_h
//
//#import <Foundation/Foundation.h>
//
//#define RIGHTS_XML_SUFFIX @"_rights.xml"
//
///// Adobe DRM error message when opening an item with past display untill date
///// The date is in `*.epub_rights.xml` files, xpath `/licenseToken/permissions/display/until`
//static NSString * _Nonnull const AdobeDRMContainerExpiredLicenseError = @"E_INVALID_LICENSE";
//
//@interface AdobeDRMContainer : NSObject
//NS_ASSUME_NONNULL_BEGIN
//- (instancetype)init NS_UNAVAILABLE;
///// Inits DRM container for the file
///// @param fileURL file URL
///// @param encryptionData encryption.xml data
//- (instancetype)initWithURL:(NSURL *)fileURL encryptionData: (NSData *)encryptionData;
///// Decrypt encrypted data for file ar path inside ePub file
///// @param data Encrypted data
///// @param path File path inside ePub file
//- (NSData *)decodeData:(NSData *)data at:(NSString *)path;
//NS_ASSUME_NONNULL_END
///// Error messages from the container or underlying classes
//@property (nonatomic, strong) NSString * _Nullable epubDecodingError;
///// Display until date from epub_rights.xml document permissions
//@property (nonatomic, strong) NSDate * _Nullable displayUntilDate;
//@property (nonatomic, strong) NSURL * _Nullable fileURL;
//@end
//
//#endif /* AdobeDRMContainer_h */
// AdobeDRMContainer.h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A DRM‐aware container that knows how to decrypt EPUB manifest items.
@interface AdobeDRMContainer : NSObject

/// The URL of the `.epub` file on disk.
@property (nonatomic, readonly) NSURL *fileURL;

/// Designated initializer
- (instancetype)initWithURL:(NSURL *)url
            encryptionData:(NSData *)encData
                 rightsData:(NSData *)rightsData
    NS_DESIGNATED_INITIALIZER;

/// The one‐shot decoder for a single entry
- (NSData *)decodeData:(NSData *)data atPath:(NSString *)path;

/// Unavailable
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
