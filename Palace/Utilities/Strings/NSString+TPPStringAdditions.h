@interface NSString (TPPStringAdditions)

- (NSString *)fileSystemSafeBase64DecodedStringUsingEncoding:(NSStringEncoding)encoding;

- (NSString *)fileSystemSafeBase64EncodedStringUsingEncoding:(NSStringEncoding)encoding;

- (NSString *)SHA256;

/**
 @returns A string made with the assumption that the receiver is a query
 param value.
 */
- (NSString *)stringURLEncodedAsQueryParamValue;

/// Determines if a string is empty not counting any whitespace characters.
/// E.g. [@" " isEmptyNoWhitespace] returns @p true.
- (BOOL)isEmptyNoWhitespace;

@end
