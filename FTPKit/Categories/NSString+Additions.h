
@interface NSString (NSString_FTPKitAdditions)

/**
 URL encode a string.
 
 @param string String to URL encode
 @return NSString Encoded URL string
 */
+ (NSString * _Nullable)FTPKitURLEncodeString:(NSString * _Nonnull)string;

/**
 URL decode a string.
 
 @param string String to URL decode
 @return NSString Decoded URL string.
 */
+ (NSString * _Nullable)FTPKitURLDecodeString:(NSString * _Nonnull)string;

- (NSString * _Nullable)FTPKitURLEncodedString;
- (NSString * _Nullable)FTPKitURLDecodedString;

- (BOOL)isIntegerValue;

@end
