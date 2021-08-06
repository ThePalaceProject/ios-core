typedef NS_ENUM(NSInteger, TPPBookContentType) {
  TPPBookContentTypeEPUB,
  TPPBookContentTypeAudiobook,
  TPPBookContentTypePDF,
  TPPBookContentTypeUnsupported
};

TPPBookContentType TPPBookContentTypeFromMIMEType(NSString *string);
