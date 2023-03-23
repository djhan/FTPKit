
extern NSString * _Nonnull const FTPErrorDomain;

@interface NSError (NSError_FTPKitAdditions)

/**
 Returns an error for the respective FTP error code.
 
 @param errorCode FTP error code
 @return NSError Respective message for error code.
 */
+ (NSError * _Nonnull)FTPKitErrorWithCode:(int)errorCode;

+ (NSError * _Nonnull)FTPKitErrorWithResponse:(NSString * _Nonnull)response;

@end
