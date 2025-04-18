//
//  AdobeDRMContainer.mm
//  The Palace Project
//
//  Created by Vladimir Fedorov on 13.05.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#ifdef FEATURE_DRM_CONNECTOR

#import "AdobeDRMContainer.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreorder"
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wshift-negative-value"
#include "dp_all.h"
#pragma clang diagnostic pop

#import "TPPXML.h"

static id acsdrm_lock = nil;

@interface AdobeDRMContainer () {
  @private dpdev::Device *device;
  @private dp::Data rightsXMLData;
  @private NSData *encryptionData;
  @private TPPXML *permissionsNode;
}
@end


@implementation AdobeDRMContainer: NSObject

@synthesize displayUntilDate = _displayUntilDate;


- (instancetype)initWithURL:(NSURL *)fileURL encryptionData:(NSData *)data {
  if (self = [super init]) {
    acsdrm_lock = [[NSObject alloc] init];
    encryptionData = data;
    self.fileURL = fileURL;
    NSString *path = fileURL.path;

    // Device data
    dpdev::DeviceProvider *deviceProvider = dpdev::DeviceProvider::getProvider(0);
    if (deviceProvider != NULL) {
      device = deviceProvider->getDevice(0);
    }

    // *_rights.xml file contents
    NSString *rightsPath = [NSString stringWithFormat:@"%@%@", path, RIGHTS_XML_SUFFIX];
    NSData *rightsData = [NSData dataWithContentsOfFile:rightsPath];
    // Keep permissions node
    TPPXML *xml = [TPPXML XMLWithData:rightsData];
    permissionsNode = [[xml firstChildWithName:@"licenseToken"] firstChildWithName:@"permissions"];
    // Pass rights data to Adobe DRM
    size_t rightsLen = rightsData.length;
    unsigned char *rightsContent = (unsigned char *)rightsData.bytes;
    rightsXMLData = dp::Data(rightsContent, rightsLen);
    
  }
  return self;
}

- (NSDate *)displayUntilDate {
  if (!_displayUntilDate) {
    /// The date is in `*.epub_rights.xml` files, xpath `/licenseToken/permissions/display/until`
    TPPXML *dateUntilNode = [[permissionsNode firstChildWithName:@"display"] firstChildWithName:@"until"];
    NSString *dateUntilValue = dateUntilNode.value;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    _displayUntilDate = [df dateFromString:dateUntilValue];
  }
  return _displayUntilDate;
}

- (NSData *)decodeData:(NSData *)data at:(NSString *)path {

  @synchronized (acsdrm_lock) {
    // clear any error
    self.epubDecodingError = nil;

    // itemInfo describes encription protocol for a file in encryption.xml
    // this way decryptor knows how to decode a block of data
    // Encryption metadata for the file from encryption.xml
    size_t encryptionLen = encryptionData.length;
    unsigned char *encryptionContent = (unsigned char *)encryptionData.bytes;
    dp::Data encryptionXMLData (encryptionContent, encryptionLen);
    dp::ref<dputils::EncryptionMetadata> encryptionMetadata = dputils::EncryptionMetadata::createFromXMLData(encryptionXMLData);
    uft::String itemPath (path.UTF8String);

    if (!encryptionMetadata) {
      self.epubDecodingError = @"Missing EncryptionMetadata";
      return data;
    }

    dp::ref<dputils::EncryptionItemInfo> itemInfo = encryptionMetadata->getItemForURI(itemPath);

    if (!itemInfo) {
      self.epubDecodingError = @"Missing EncryptionItemInfo";
      return data;
    }
    
    if (rightsXMLData.isNull()) {
      self.epubDecodingError = @"Missing Rights XML Data";
      return data;
    }
    
    if (!device) {
      self.epubDecodingError = @"Device information is empty";
      return data;
    }

    // Create decryptor
    dp::String decryptorEerror;
    dp::ref<dputils::EPubManifestItemDecryptor> decryptor = dpdrm::DRMProcessor::createEPubManifestItemDecryptor(itemInfo, rightsXMLData, device, decryptorEerror);

    if (!decryptor) {
      if (!decryptorEerror.isNull()) {
        self.epubDecodingError = [NSString stringWithUTF8String:decryptorEerror.utf8()];
      }
      return data;
    }
    
    // Buffer for decrypted data
    dp::ref<dp::Buffer> filteredData = NULL;
    // data is the first and the last block (the whole block of data is decoded at once)
    int blockType = dputils::EPubManifestItemDecryptor::FIRST_BLOCK | dputils::EPubManifestItemDecryptor::FINAL_BLOCK;
    size_t len = data.length;
    uint8_t *encryptedData = (uint8_t *)data.bytes;
    dp::String error = decryptor->decryptBlock(blockType, encryptedData, len, NULL, filteredData);
    if (!error.isNull()) {
      self.epubDecodingError = [NSString stringWithUTF8String:error.utf8()];
      return data;
    }
    return [NSData dataWithBytes:filteredData->data() length: NSUInteger(filteredData->length())];
  }
}

@end

#endif
