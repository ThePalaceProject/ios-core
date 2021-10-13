#import "TPPAttributedString.h"

NSAttributedString *TPPAttributedStringForAuthorsFromString(NSString *string)
{
  if(!string) return nil;
  
  NSMutableParagraphStyle *const paragraphStyle = [[NSMutableParagraphStyle alloc] init];
  paragraphStyle.lineSpacing = 0.0;
  paragraphStyle.minimumLineHeight = 0.0;
  paragraphStyle.lineHeightMultiple = 0.9;
  paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;
  paragraphStyle.hyphenationFactor = 0.85;
  
  return [[NSAttributedString alloc]
          initWithString:string
          attributes:@{NSParagraphStyleAttributeName: paragraphStyle}];
}

NSAttributedString *TPPAttributedStringForTitleFromString(NSString *string)
{
  if(!string) return nil;

  NSString *decodedString = string;
  
  NSData *stringData = [string dataUsingEncoding:NSUTF8StringEncoding];
  if (!stringData) return nil;
  
  // Decode HTML entities using NSAttributedString
  NSDictionary<NSAttributedStringDocumentReadingOptionKey, id> *options = @{
    NSDocumentTypeDocumentAttribute : NSHTMLTextDocumentType,
    NSCharacterEncodingDocumentAttribute :@(NSUTF8StringEncoding)
  };
  
  NSError *error;
  NSAttributedString *decodedAttributedString = [[NSAttributedString alloc] initWithData:stringData options:options documentAttributes:nil error:&error];
  if (!error) {
    decodedString = decodedAttributedString.string;
  }

  NSMutableParagraphStyle *const paragraphStyle = [[NSMutableParagraphStyle alloc] init];
  paragraphStyle.lineSpacing = 0.0;
  paragraphStyle.minimumLineHeight = 0.0;
  paragraphStyle.lineHeightMultiple = 0.85;
  paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;
  paragraphStyle.hyphenationFactor = 0.75;
  
  return [[NSAttributedString alloc]
          initWithString:decodedString
          attributes:@{NSParagraphStyleAttributeName: paragraphStyle}];
}
