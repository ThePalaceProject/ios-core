//
//  TPPEncryptedPDFDataProvider.h
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TPPEncryptedPDFDataProvider : NSObject

- (instancetype)initWithData:(NSData *)data decryptor:(NSData * (^)(NSData *data, NSUInteger start, NSUInteger end))decryptor;

- (CGDataProviderRef)dataProvider;

@end

NS_ASSUME_NONNULL_END
