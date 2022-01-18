#import "TPPBookContentType.h"
#import "TPPOPDSAcquisitionPath.h"

TPPBookContentType TPPBookContentTypeFromMIMEType(NSString *const string)
{
  if ([[TPPOPDSAcquisitionPath audiobookTypes] containsObject:string]) {
    return TPPBookContentTypeAudiobook;
  } else if ([string isEqualToString:ContentTypeEpubZip] || [string isEqualToString:ContentTypeOctetStream]) {
    return TPPBookContentTypeEPUB;
  } else if ([string isEqualToString:ContentTypeOpenAccessPDF]) {
    return TPPBookContentTypePDF;
  }
  return TPPBookContentTypeUnsupported;
}
