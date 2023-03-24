//
//  NSDate+NSDate_Additions.m
//  FTPKit
//
//  Created by DJ.HAN on 2023/03/24.
//  Copyright © 2023 Upstart Illustration LLC. All rights reserved.
//

#import "NSDate+NSDate_Additions.h"

@implementation NSDate (NSDate_Additions)

/**
 표시용 스트링으로 변환
 
 @returns 표시용 NSString
 */
- (NSString * _Nonnull)string {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy/MM/dd, HH:mm"];
    return [dateFormatter stringFromDate:self];
}

@end
