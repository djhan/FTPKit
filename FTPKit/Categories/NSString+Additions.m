#import "NSString+Additions.h"

@implementation NSString (NSString_FTPKitAdditions)

+ (NSString *)FTPKitURLEncodeString:(NSString *)unescaped
{
    return [unescaped stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"!*'();:@&=+$,?%#[]\" "]];
}

+ (NSString *)FTPKitURLDecodeString:(NSString *)string
{
    return [string stringByRemovingPercentEncoding];
}

- (NSString *)FTPKitURLEncodedString
{
    return [NSString FTPKitURLEncodeString:self];
}

- (NSString *)FTPKitURLDecodedString
{
    return [NSString FTPKitURLDecodeString:self];
}

- (BOOL)isIntegerValue
{
    NSScanner *scanner = [NSScanner scannerWithString:self];
    if ([scanner scanInteger:NULL]) {
        return [scanner isAtEnd];
    }
    return NO;
}

@end
