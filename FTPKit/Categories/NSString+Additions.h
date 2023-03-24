
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

/**
 URL 인코딩 경로 반환

 현재 String이 FTP 상에 존재하는 파일 경로인 경우, 퍼센트 인코딩을 제거한 경로로 변환해서 반환

 @returns 퍼센트 인코딩이 제거된 경로로 반환
 */
- (NSString * _Nullable)urlEncodedString;

- (BOOL)isIntegerValue;

/// 파일 경로인 경우, 로컬 파일 크기 구하기.
- (long long int)fileSize;

@end
