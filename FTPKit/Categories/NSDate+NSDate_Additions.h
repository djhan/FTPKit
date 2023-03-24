//
//  NSDate+NSDate_Additions.h
//  FTPKit
//
//  Created by DJ.HAN on 2023/03/24.
//  Copyright © 2023 Upstart Illustration LLC. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSDate (NSDate_Additions)

/**
 표시용 스트링으로 변환
 
 @returns 표시용 NSString
 */
- (NSString * _Nonnull)string;

@end

NS_ASSUME_NONNULL_END
