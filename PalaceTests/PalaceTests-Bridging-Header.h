//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "Palace-Bridging-Header.h"
#import "TPPOpenSearchDescription.h"
#import "NSString+TPPStringAdditions.h"
#import "TPPBook.h"

//
// Override here any ObjC declarations to facilitate testing
//

@interface TPPOpenSearchDescription ()
@property (nonatomic, readwrite, nullable) NSString *OPDSURLTemplate;
@end

@interface UIColor ()
- (nullable NSString *)javascriptHexString;
@end

@interface TPPBook ()
- (nonnull instancetype)initWithAcquisitions:(nonnull NSArray<TPPOPDSAcquisition *> *)acquisitions
                                 bookAuthors:(nullable NSArray<TPPBookAuthor *> *)authors
                             categoryStrings:(nullable NSArray *)categoryStrings
                                 distributor:(nullable NSString *)distributor
                                  identifier:(nonnull NSString *)identifier
                                    imageURL:(nullable NSURL *)imageURL
                           imageThumbnailURL:(nullable NSURL *)imageThumbnailURL
                                   published:(nullable NSDate *)published
                                   publisher:(nullable NSString *)publisher
                                    subtitle:(nullable NSString *)subtitle
                                     summary:(nullable NSString *)summary
                                       title:(nonnull NSString *)title
                                     updated:(nonnull NSDate *)updated
                              annotationsURL:(nullable NSURL *) annotationsURL
                                analyticsURL:(nullable NSURL *)analyticsURL
                                alternateURL:(nullable NSURL *)alternateURL
                             relatedWorksURL:(nullable NSURL *)relatedWorksURL
                                   seriesURL:(nullable NSURL *)seriesURL
                                   revokeURL:(nullable NSURL *)revokeURL
                                   reportURL:(nullable NSURL *)reportURL
                                contributors:(nullable NSDictionary *)contributors;
@end
