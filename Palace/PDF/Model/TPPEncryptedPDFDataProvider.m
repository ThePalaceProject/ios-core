//
//  TPPEncryptedPDFDataProvider.m
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

#import "TPPEncryptedPDFDataProvider.h"

/// Data providers are fully discussed here:
/// https://developer.apple.com/documentation/coregraphics/cgdataprovider
/// TPPPDFReader uses `CGDataProviderDirectCallbacks` to get the access to blocks of encrypted data.

@implementation TPPEncryptedPDFDataProvider

NSData *_encryptedData;
NSData * (^_decryptor)(NSData *data, NSUInteger start, NSUInteger end);

static const void *dataPointer(__attribute__((unused)) void *info) {
  return info;
}

static void releaseData(__attribute__((unused)) void *info, const void *pointer) {
  free(pointer);
}

static size_t bytesAtPosition(__attribute__((unused)) void *info, void *buffer, off_t pos, size_t n) {
  NSUInteger start = pos;
  NSUInteger end = pos + n;
  NSData *data = _decryptor(_encryptedData, start, end);
  memcpy(buffer, data.bytes, n);
  return n;
}

static void releaseInfo(void *info) {
  free(info);
}

static CGDataProviderDirectCallbacks callbacks = {
  0,
  dataPointer,
  releaseData,
  bytesAtPosition,
  releaseInfo,
};

-(id)initWithData:(NSData *)data decryptor:(NSData * (^)(NSData *data, NSUInteger start, NSUInteger end))decryptor {
  self = [super init];
  _encryptedData = data;
  _decryptor = decryptor;
  return self;
}

- (CGDataProviderRef)dataProvider {
  CGDataProviderRef dataProvider = CGDataProviderCreateDirect(nil, _encryptedData.length, &callbacks);
  return dataProvider;
}

@end
