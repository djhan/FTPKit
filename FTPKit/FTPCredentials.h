
@interface FTPCredentials : NSObject

@property (nonatomic, readonly) NSString * _Nonnull host;
@property (nonatomic, readonly) int port;
@property (nonatomic, readonly) NSString * _Nonnull username;
@property (nonatomic, readonly) NSString * _Nonnull password;

/**
 Factory: Create credentials used for login.
 
 @param host Host of server.
 @param port Server port.
 @param username Username used to connect to server.
 @param password User's password.
 @return FTPCredentials
 */
+ (instancetype _Nonnull)credentialsWithHost:(NSString * _Nonnull)host
                                        port:(int)port
                                    username:(NSString * _Nonnull)username
                                    password:(NSString * _Nonnull)password;

/**
 Create credentials used for login.
 
 @param host Host of server.
 @param port Server port.
 @param username Username used to connect to server.
 @param password User's password.
 @return FTPCredentials
 */
- (id _Nonnull)initWithHost:(NSString * _Nonnull)host
                       port:(int)port
                   username:(NSString * _Nonnull)username
                   password:(NSString * _Nonnull)password;

/**
 Creates fully qualified FTP URL including schema, credentials and the absolute
 path to the resource.
 
 @param path Path to remote resource. The path should never contain schema, etc.
 @return NSURL URL for path.
 */
- (NSURL * _Nullable)urlForPath:(NSString * _Nonnull)path;

@end
