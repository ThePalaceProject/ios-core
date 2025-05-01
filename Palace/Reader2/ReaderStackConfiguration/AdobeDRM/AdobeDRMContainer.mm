//
//  AdobeDRMContainer.mm
//  The Palace Project
//
//  Created by Vladimir Fedorov on 13.05.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

//#ifdef FEATURE_DRM_CONNECTOR
//
//#import "AdobeDRMContainer.h"
//#pragma clang diagnostic push
//#pragma clang diagnostic ignored "-Wreorder"
//#pragma clang diagnostic ignored "-Wunused-parameter"
//#pragma clang diagnostic ignored "-Wshift-negative-value"
//#include "dp_all.h"
//#pragma clang diagnostic pop
//
//#import "TPPXML.h"
//
//static id acsdrm_lock = nil;
//
//@interface AdobeDRMContainer () {
//  @private dpdev::Device *device;
//  @private dp::Data rightsXMLData;
//  @private NSData *encryptionData;
//  @private TPPXML *permissionsNode;
//}
//@end
//
//
//@implementation AdobeDRMContainer: NSObject
//
//@synthesize displayUntilDate = _displayUntilDate;
//
//
//- (instancetype)initWithURL:(NSURL *)fileURL encryptionData:(NSData *)data {
//  if (self = [super init]) {
//    acsdrm_lock = [[NSObject alloc] init];
//    encryptionData = data;
//    self.fileURL = fileURL;
//    NSString *path = fileURL.path;
//
//    // Device data
//    dpdev::DeviceProvider *deviceProvider = dpdev::DeviceProvider::getProvider(0);
//    if (deviceProvider != NULL) {
//      device = deviceProvider->getDevice(0);
//    }
//
//    // *_rights.xml file contents
//    NSString *rightsPath = [NSString stringWithFormat:@"%@%@", path, RIGHTS_XML_SUFFIX];
//    NSData *rightsData = [NSData dataWithContentsOfFile:rightsPath];
//    // Keep permissions node
//    TPPXML *xml = [TPPXML XMLWithData:rightsData];
//    permissionsNode = [[xml firstChildWithName:@"licenseToken"] firstChildWithName:@"permissions"];
//    // Pass rights data to Adobe DRM
//    size_t rightsLen = rightsData.length;
//    unsigned char *rightsContent = (unsigned char *)rightsData.bytes;
//    rightsXMLData = dp::Data(rightsContent, rightsLen);
//    
//  }
//  return self;
//}
//
//- (NSDate *)displayUntilDate {
//  if (!_displayUntilDate) {
//    /// The date is in `*.epub_rights.xml` files, xpath `/licenseToken/permissions/display/until`
//    TPPXML *dateUntilNode = [[permissionsNode firstChildWithName:@"display"] firstChildWithName:@"until"];
//    NSString *dateUntilValue = dateUntilNode.value;
//    NSDateFormatter *df = [[NSDateFormatter alloc] init];
//    df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
//    _displayUntilDate = [df dateFromString:dateUntilValue];
//  }
//  return _displayUntilDate;
//}
//
//- (NSData *)decodeData:(NSData *)data at:(NSString *)path {
//
//  @synchronized (acsdrm_lock) {
//    // clear any error
//    self.epubDecodingError = nil;
//
//    // itemInfo describes encription protocol for a file in encryption.xml
//    // this way decryptor knows how to decode a block of data
//    // Encryption metadata for the file from encryption.xml
//    size_t encryptionLen = encryptionData.length;
//    unsigned char *encryptionContent = (unsigned char *)encryptionData.bytes;
//    dp::Data encryptionXMLData (encryptionContent, encryptionLen);
//    dp::ref<dputils::EncryptionMetadata> encryptionMetadata = dputils::EncryptionMetadata::createFromXMLData(encryptionXMLData);
//    uft::String itemPath (path.UTF8String);
//
//    if (!encryptionMetadata) {
//      self.epubDecodingError = @"Missing EncryptionMetadata";
//      return data;
//    }
//
//    dp::ref<dputils::EncryptionItemInfo> itemInfo = encryptionMetadata->getItemForURI(itemPath);
//
//    if (!itemInfo) {
//      self.epubDecodingError = @"Missing EncryptionItemInfo";
//      return data;
//    }
//    
//    if (rightsXMLData.isNull()) {
//      self.epubDecodingError = @"Missing Rights XML Data";
//      return data;
//    }
//    
//    if (!device) {
//      self.epubDecodingError = @"Device information is empty";
//      return data;
//    }
//
//    // Create decryptor
//    dp::String decryptorEerror;
//    dp::ref<dputils::EPubManifestItemDecryptor> decryptor = dpdrm::DRMProcessor::createEPubManifestItemDecryptor(itemInfo, rightsXMLData, device, decryptorEerror);
//
//    if (!decryptor) {
//      if (!decryptorEerror.isNull()) {
//        self.epubDecodingError = [NSString stringWithUTF8String:decryptorEerror.utf8()];
//      }
//      return data;
//    }
//    
//    // Buffer for decrypted data
//    dp::ref<dp::Buffer> filteredData = NULL;
//    // data is the first and the last block (the whole block of data is decoded at once)
//    int blockType = dputils::EPubManifestItemDecryptor::FIRST_BLOCK | dputils::EPubManifestItemDecryptor::FINAL_BLOCK;
//    size_t len = data.length;
//    uint8_t *encryptedData = (uint8_t *)data.bytes;
//    dp::String error = decryptor->decryptBlock(blockType, encryptedData, len, NULL, filteredData);
//    if (!error.isNull()) {
//      self.epubDecodingError = [NSString stringWithUTF8String:error.utf8()];
//      return data;
//    }
//    return [NSData dataWithBytes:filteredData->data() length: NSUInteger(filteredData->length())];
//  }
//}
//
//@end
//
//#endif

// AdobeDRMContainer.mm

// AdobeDRMContainer.mm
// The Palace Project
// Replaces the old .mm/.h by shipping in raw rights+encryption blobs and path strings.
//
// NOTE: All ZIP/archive work must happen in Swift.  This shim ONLY does C++ decryption.

#import "AdobeDRMContainer.h"
#import "TPPXML.h"

#pragma clang diagnostic push
// suppress warnings from dp_all.h if you like:
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdeprecated"
#pragma clang diagnostic ignored "-Wweak-vtables"
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wold-style-cast"
#pragma clang diagnostic ignored "-Wcast-align"
#pragma clang diagnostic ignored "-Wreorder"
#pragma clang diagnostic ignored "-Wpadded"
#pragma clang diagnostic ignored "-Wshift-negative-value"
#pragma clang diagnostic ignored "-Wundef"
#pragma clang diagnostic ignored "-Wextra-semi"
#pragma clang diagnostic ignored "-Wglobal-constructors"
#pragma clang diagnostic ignored "-Wreserved-id-macro"
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wfloat-equal"
#pragma clang diagnostic ignored "-Wswitch-enum"
#pragma clang diagnostic ignored "-Wunreachable-code"
#pragma clang diagnostic ignored "-Wnullability-completeness"
// …etc
#pragma clang diagnostic pop

#include <dp_all.h>    // <-- must be angle-brackets so Xcode uses your Header Search Paths

static NSObject *sDRMLock = nil;

@implementation AdobeDRMContainer {
  dpdev::Device    *_device;
  dp::Data          _rightsXMLData;
  NSData           *_encryptionData;
}

- (instancetype)initWithURL:(NSURL *)url
            encryptionData:(NSData *)encData
                 rightsData:(NSData *)rightsData
{
  if (!(self = [super init])) return nil;
  // 1) stash URL
  _fileURL = url;
  // 2) stash DRM blobs
  _encryptionData = [encData copy];
  _rightsXMLData  = dp::Data((unsigned char*)rightsData.bytes, rightsData.length);
  // 3) platform + device init…
  dp::platformInit(dp::PI_DEFAULT);
  dp::cryptRegisterOpenSSL();
  dp::deviceRegisterPrimary();
  dp::deviceRegisterExternal();
  auto provider = dpdev::DeviceProvider::getProvider(0);
  _device = provider ? provider->getDevice(0) : nullptr;
  return self;
}

- (NSData *)decodeData:(NSData *)encryptedData
               atPath:(NSString *)path
{
  @synchronized(sDRMLock) {
    // 1) Build the EncryptionMetadata from the XML blob
    dp::Data encXML(
      (const unsigned char *)_encryptionData.bytes,
      _encryptionData.length
    );
    auto metadata = dputils::EncryptionMetadata::createFromXMLData(encXML);
    if (!metadata) {
      return encryptedData;
    }

    // 2) Look up the EncryptionItemInfo for this manifest URI
    uft::String uri(path.UTF8String);
    auto itemInfo = metadata->getItemForURI(uri);
    if (!itemInfo) {
      return encryptedData;
    }

    // 3) Sanity‐check that we have rights and a device
    if (_rightsXMLData.isNull() || _device == nullptr) {
      return encryptedData;
    }

    // 4) Create the decryptor
    dp::String error;
    auto decryptor =
      dpdrm::DRMProcessor::createEPubManifestItemDecryptor(
        itemInfo,
        _rightsXMLData,
        _device,
        error
      );
    if (!decryptor) {
      return encryptedData;
    }

    // 5) Decrypt in a single FIRST_BLOCK|FINAL_BLOCK pass
    dp::ref<dp::Buffer> outBuf;
    int flags =
      dputils::EPubManifestItemDecryptor::FIRST_BLOCK
      | dputils::EPubManifestItemDecryptor::FINAL_BLOCK;
    dp::String code = decryptor->decryptBlock(
      flags,
      // cast away const so signature matches:
      (uint8_t *)encryptedData.bytes,
      encryptedData.length,
      nullptr,
      outBuf
    );

    // 6) If the dp::String `code` is non-empty OR we didn’t get a buffer, bail
    if (!code.isNull() || !outBuf) {
      return encryptedData;
    }

    // 7) Wrap the decrypted bytes in an NSData and return
    return [NSData dataWithBytes:outBuf->data()
                          length:outBuf->length()];
  }
}

@end
