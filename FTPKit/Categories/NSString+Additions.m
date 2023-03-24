#import "NSString+Additions.h"

@implementation NSString (NSString_FTPKitAdditions)

+ (NSString *)FTPKitURLEncodeString:(NSString *)unescaped {
    return [unescaped stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"!*'();:@&=+$,?%#[]\" "]];
}

+ (NSString *)FTPKitURLDecodeString:(NSString *)string {
    return [string stringByRemovingPercentEncoding];
}

- (NSString *)FTPKitURLEncodedString {
    return [NSString FTPKitURLEncodeString:self];
}

- (NSString *)FTPKitURLDecodedString {
    return [NSString FTPKitURLDecodeString:self];
}

- (NSString *)urlEncodedString {
    return [self stringByRemovingPercentEncoding];
}

- (BOOL)isIntegerValue {
    NSScanner *scanner = [NSScanner scannerWithString:self];
    if ([scanner scanInteger:NULL]) {
        return [scanner isAtEnd];
    }
    return NO;
}

/// 파일 경로인 경우, 로컬 파일 크기 구하기.
- (long long int)fileSize {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:self] == false) {
        return false;
    }
    NSError *error = NULL;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self error:&error];
    if (error != NULL) {
        //NSLog(@"Error = %@", [error description]);
        return false;
    }
    return [[fileAttributes objectForKey:NSFileSize] longLongValue];
}

@end
