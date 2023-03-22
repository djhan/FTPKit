#import "ftplib.h"
#import "ftpparse.h"
#import "FTPKit+Protected.h"
#import "FTPClient.h"
#import "NSError+Additions.h"

// MARK: - FTPItem Class -
/**
 FTPItem Class
 */
@implementation FTPItem

- (void)dealloc {
    if (_filename != NULL) {
        _filename = NULL;
    }
    if (_modificationDate != NULL) {
        _modificationDate = NULL;
    }
}

/**
 초기화
 @param filename    파일명
 @param isDir       디렉토리 여부
 @param isHidden    감춤 파일 여부
 @param size        파일 크기
 @param date        수정일
 */
- (instancetype)initWithFilename:(nonnull NSString *)filename
                           isDir:(bool)isDir
                        isHidden:(bool)isHidden
                            size:(long int)size
                modificationDate:(nullable NSDate *)modificationDate
{
    self = [super init];
    if (self ) {
        _filename = filename;
        _isDir = isDir;
        _isHidden = isHidden;
        _size = size;
        _modificationDate = modificationDate;
    }
    return self;
}

@end


// MARK: - FTPClient Class -
/**
 FTPClient Class
 */
@interface FTPClient ()

@property (nonatomic, strong) FTPCredentials* credentials;

/** Queue used to enforce requests to process in synchronous order. */
@property (nonatomic, strong) dispatch_queue_t queue;

/** The last error encountered. */
@property (nonatomic, strong) NSError *lastError;

/** NSString Encoding */
@property (nonatomic) int encoding;

/**
 Create connection to FTP server.
 
 @return netbuf The connection to the FTP server on success. NULL otherwise.
 */
- (netbuf *)connect;

/**
 Send arbitrary command to the FTP server.
 
 @param command Command to send to the FTP server.
 @param netbuf Connection to FTP server.
 @return BOOL YES on success. NO otherwise.
 */
- (BOOL)sendCommand:(NSString *)command conn:(netbuf *)conn;

/**
 Returns a URL that can be used to write temporary data to.
 
 Make sure to remove the file after you are done using it!
 
 @return String to temporary path.
 */
- (NSString *)temporaryUrl;

- (NSDictionary *)entryByReencodingNameInEntry:(NSDictionary *)entry encoding:(NSStringEncoding)newEncoding;

/**
 Parse data returned from FTP LIST command.
 
 @param data Bytes returned from server containing directory listing.
 @param handle Parent directory handle.
 @param showHiddenFiles Ignores hiddent files if YES. Otherwise returns all files.
 @return List of FTPHandle objects.
 */
- (NSArray *)parseListData:(NSData *)data handle:(FTPHandle *)handle showHiddentFiles:(BOOL)showHiddenFiles;

/**
 Sets lastError w/ 'message' as description and error code 502.
 
 @param message Description to set to last error.
 */
- (void)failedWithMessage:(NSString *)message;

/**
 Convenience method that wraps failure(error) in dispatch_async(main_queue)
 and ensures that the error is copied before sending back to callee -- to ensure
 it doesn't get nil'ed out by the next command before the callee has a chance
 to read the error.
 */
- (void)returnFailureLastError:(void (^)(NSError *error))failure;

/**
 URL encode a path.
 
 This method is used only on _existing_ files on the FTP server.
 
 @param path The path to URL encode.
 */
- (NSString *)urlEncode:(NSString *)path;

@end

@implementation FTPClient

+ (instancetype)clientWithCredentials:(FTPCredentials *)credentials
{
	return [[self alloc] initWithCredentials:credentials];
}

+ (instancetype)clientWithHost:(NSString *)host
                          port:(int)port
                      encoding:(int)encoding
                      username:(NSString *)username
                      password:(NSString *)password
{
    return [[self alloc] initWithHost:host port:port encoding:encoding username:username password:password];
}

- (instancetype)initWithCredentials:(FTPCredentials *)aLocation
{
    self = [super init];
	if (self) {
		self.credentials = aLocation;
        self.queue = dispatch_queue_create("com.upstart-illustration-llc.FTPKitQueue", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    encoding:(int)encoding
                    username:(NSString *)username
                    password:(NSString *)password
{
    FTPCredentials *creds = [FTPCredentials credentialsWithHost:host port:port username:username password:password];
    _encoding = encoding;
	return [self initWithCredentials:creds];
}

- (NSString *)urlEncode:(NSString *)path
{
    return [path stringByRemovingPercentEncoding];
    //return [path stringByReplacingPercentEscapesUsingEncoding:_encoding];
}

- (long long int)fileSizeAtPath:(NSString *)path
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return -1;
    const char *cPath = [[self urlEncode:path] cStringUsingEncoding:_encoding];
    unsigned int bytes;
    int stat = FtpSize(cPath, &bytes, FTPLIB_BINARY, conn);
    FtpQuit(conn);
    if (stat == 0) {
        FKLogError(@"File most likely does not exist %@", path);
        return -1;
    }
    FKLogDebug(@"%@ bytes %d", path, bytes);
    return (long long int)bytes;
}

- (NSArray *)listContentsAtPath:(NSString *)path showHiddenFiles:(BOOL)showHiddenFiles
{
    FTPHandle *hdl = [FTPHandle handleAtPath:path type:FTPHandleTypeDirectory];
    return [self listContentsAtHandle:hdl showHiddenFiles:showHiddenFiles];
}
- (NSArray *)getListContentsAtPath:(NSString *)path showHiddenFiles:(BOOL)showHiddenFiles
{
    FTPHandle *hdl = [FTPHandle handleAtPath:path type:FTPHandleTypeDirectory];
    return [self getListContentsAtHandle:hdl showHiddenFiles:showHiddenFiles];
}

- (void)listContentsAtPath:(NSString *)path showHiddenFiles:(BOOL)showHiddenFiles success:(void (^)(NSArray *))success failure:(void (^)(NSError *))failure
{
    FTPHandle *hdl = [FTPHandle handleAtPath:path type:FTPHandleTypeDirectory];
    [self listContentsAtHandle:hdl showHiddenFiles:showHiddenFiles success:success failure:failure];
}

/**
 목록을 가져오는 메쏘드
 @param handle `FTPHandle`
 @param showHiddenFiles 감춤 파일 표시 여부
 */
- (NSArray *)getListContentsAtHandle:(FTPHandle *)handle showHiddenFiles:(BOOL)showHiddenFiles
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return nil;
    const char *path = [[self urlEncode:handle.path] cStringUsingEncoding:_encoding];
    // 리스트 결과값 초기화
    printf("int max = %i", INT_MAX);
    char *bufferData = NULL;
    int stat = FtpDirData(&bufferData, path, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0 ||
        strlen(bufferData) == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        // 리스트 결과값을 해제 (반드시 필요)
        if (bufferData != NULL) {
            free(bufferData);
        }
        return nil;
    }
    NSArray *files = [self parseList:bufferData showHiddentFiles:showHiddenFiles];
    // 리스트 결과값을 해제 (반드시 필요)
    if (bufferData != NULL) {
        free(bufferData);
    }
    return files;
}

- (NSArray *)listContentsAtHandle:(FTPHandle *)handle showHiddenFiles:(BOOL)showHiddenFiles
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return nil;
    const char *path = [[self urlEncode:handle.path] cStringUsingEncoding:_encoding];
    NSString *tmpPath = [self temporaryUrl];
    const char *output = [tmpPath cStringUsingEncoding:_encoding];
    int stat = FtpDir(output, path, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return nil;
    }
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:tmpPath options:NSDataReadingUncached error:&error];
    if (error) {
        FKLogError(@"Error: %@", error.localizedDescription);
        self.lastError = error;
        return nil;
    }
    /**
     Please note: If there are no contents in the folder OR if the folder does
     not exist data.bytes _will_ be 0. Therefore, you can not use this method to
     determine if a directory exists!
     */
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:&error];
    // Log the error, but do not fail.
    if (error) {
        FKLogError(@"Failed to remove tmp file. Error: %@", error.localizedDescription);
    }
    NSArray *files = [self parseListData:data handle:handle showHiddentFiles:showHiddenFiles];
    return files; // If files == nil, method will set the lastError.
}

- (void)listContentsAtHandle:(FTPHandle *)handle showHiddenFiles:(BOOL)showHiddenFiles success:(void (^)(NSArray *))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        NSArray *contents = [self listContentsAtHandle:handle showHiddenFiles:showHiddenFiles];
        if (contents && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(contents);
            });
        } else if (! contents && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)downloadFile:(NSString *)remotePath to:(NSString *)localPath progress:(BOOL (^)(NSUInteger, NSUInteger))progress
{
    return [self downloadHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeFile] to:localPath progress:progress];
}

- (void)downloadFile:(NSString *)remotePath to:(NSString *)localPath progress:(BOOL (^)(NSUInteger, NSUInteger))progress success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    [self downloadHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeFile]  to:localPath progress:progress success:success failure:failure];
}

/**
 FTP 경로에서 데이터 읽기.
 */
- (NSData * _Nullable)downloadFile:(NSString * _Nonnull)remotePath
                            offset:(long long int)offset
                            length:(long long int)length
                          progress:(void (^ _Nullable)(NSUInteger received, NSUInteger totalBytes))progress
                           failure:(void (^ _Nonnull)(NSError * _Nullable error))failure {
    netbuf *conn = [self connect];
    FTPHandle *handle = [FTPHandle handleAtPath:remotePath type:FTPHandleTypeFile];
    if (conn == NULL)
        return NULL;
    
    char *bufferData;
    const char *path = [[self urlEncode:handle.path] cStringUsingEncoding:self.encoding];
    int stat = FtpGetData(&bufferData, path, FTPLIB_BINARY, offset, length, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:self.encoding];
    FtpQuit(conn);
    if (stat == 0) {
        NSError *error = [NSError FTPKitErrorWithResponse:response];
        [self returnFailure:failure error:error];
    }
    if (bufferData == NULL &&
        strlen(bufferData) >= length) {
        NSString *response = NSLocalizedString(@"Failed to download file.", @"");
        NSError *error = [NSError FTPKitErrorWithResponse:response];
        [self returnFailure:failure error:error];
    }
    
    return [[NSData alloc] initWithBytes:bufferData length:length];
}

- (BOOL)downloadHandle:(FTPHandle *)handle to:(NSString *)localPath progress:(BOOL (^)(NSUInteger, NSUInteger))progress
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *output = [localPath cStringUsingEncoding:_encoding];
    const char *path = [[self urlEncode:handle.path] cStringUsingEncoding:_encoding];
    // @todo Send w/ appropriate mode. FTPLIB_ASCII | FTPLIB_BINARY
    int stat = FtpGet(output, path, FTPLIB_BINARY, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    // @todo Use 'progress' block.
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)downloadHandle:(FTPHandle *)handle to:(NSString *)localPath progress:(BOOL (^)(NSUInteger, NSUInteger))progress success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self downloadHandle:handle to:localPath progress:progress];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        } else if (! ret && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)uploadFile:(NSString *)localPath to:(NSString *)remotePath progress:(BOOL (^)(NSUInteger, NSUInteger))progress
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *input = [localPath cStringUsingEncoding:_encoding];
    const char *path = [remotePath cStringUsingEncoding:_encoding];
    // @todo Send w/ appropriate mode. FTPLIB_ASCII | FTPLIB_BINARY
    int stat = FtpPut(input, path, FTPLIB_BINARY, conn);
    // @todo Use 'progress' block.
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        // Invalid path, wrong permissions, etc. Make sure that permissions are
        // set corectly on the path AND the path of the initialPath is correct.
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)uploadFile:(NSString *)localPath to:(NSString *)remotePath progress:(BOOL (^)(NSUInteger, NSUInteger))progress success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self uploadFile:localPath to:remotePath progress:progress];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        } else if (! ret && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)createDirectoryAtPath:(NSString *)remotePath
{
    return [self createDirectoryAtHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeDirectory]];
}

- (void)createDirectoryAtPath:(NSString *)remotePath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    [self createDirectoryAtHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeDirectory] success:success failure:failure];
}

- (BOOL)createDirectoryAtHandle:(FTPHandle *)handle
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *path = [handle.path cStringUsingEncoding:_encoding];
    int stat = FtpMkdir(path, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)createDirectoryAtHandle:(FTPHandle *)handle success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
	dispatch_async(_queue, ^{
        BOOL ret = [self createDirectoryAtHandle:handle];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        } else if (! ret && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)deleteDirectoryAtPath:(NSString *)remotePath
{
    return [self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeDirectory]];
}

- (void)deleteDirectoryAtPath:(NSString *)remotePath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    [self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeDirectory] success:success failure:failure];
}

- (BOOL)deleteFileAtPath:(NSString *)remotePath
{
    return [self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeFile]];
}

- (void)deleteFileAtPath:(NSString *)remotePath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    [self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeFile] success:success failure:failure];
}

- (BOOL)deleteHandle:(FTPHandle *)handle
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *path = [[self urlEncode:handle.path] cStringUsingEncoding:_encoding];
    int stat = 0;
    if (handle.type == FTPHandleTypeDirectory)
        stat = FtpRmdir(path, conn);
    else
        stat = FtpDelete(path, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)deleteHandle:(FTPHandle *)handle success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self deleteHandle:handle];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        } else if (! ret && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)chmodPath:(NSString *)remotePath toMode:(int)mode
{
    return [self chmodHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeUnknown] toMode:mode];
}

- (void)chmodPath:(NSString *)remotePath toMode:(int)mode success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    [self chmodHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeUnknown] toMode:mode success:success failure:failure];
}

- (BOOL)chmodHandle:(FTPHandle *)handle toMode:(int)mode
{
    if (mode < 0 || mode > 777) {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:NSLocalizedString(@"File mode value must be between 0 and 0777.", @"")
                                                             forKey:NSLocalizedDescriptionKey];
        self.lastError = [[NSError alloc] initWithDomain:FTPErrorDomain code:0 userInfo:userInfo];
        return NO;
    }
    NSString *command = [NSString stringWithFormat:@"SITE CHMOD %i %@", mode, [self urlEncode:handle.path]];
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    BOOL success = [self sendCommand:command conn:conn];
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (! success) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)chmodHandle:(FTPHandle *)handle toMode:(int)mode success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self chmodHandle:handle toMode:mode];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        } else if (! ret && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)renamePath:(NSString *)sourcePath to:(NSString *)destPath
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *src = [[self urlEncode:sourcePath] cStringUsingEncoding:_encoding];
    // @note The destination path does not need to be URL encoded. In fact, if
    // it is, the filename will include the percent escaping!
    const char *dst = [destPath cStringUsingEncoding:_encoding];
    int stat = FtpRename(src, dst, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)renamePath:(NSString *)sourcePath to:(NSString *)destPath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self renamePath:sourcePath to:destPath];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        } else if (! ret && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)copyPath:(NSString *)sourcePath to:(NSString *)destPath
{
    NSString *tmpPath = [self temporaryUrl];
    BOOL success = [self downloadFile:sourcePath to:tmpPath progress:NULL];
    if (! success)
        return NO;
    success = [self uploadFile:tmpPath to:destPath progress:NULL];
    // Remove file.
    NSError *error;
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:&error];
    // Log the error, but do not fail.
    if (error) {
        FKLogError(@"Failed to remove tmp file. Error: %@", error.localizedDescription);
    }
    if (! success)
        return NO;
    return YES;
}

- (void)copyPath:(NSString *)sourcePath to:(NSString *)destPath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self copyPath:sourcePath to:destPath];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        } else if (! ret && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

/** Private Methods */

- (netbuf *)connect
{
    self.lastError = nil;
    const char *host = [_credentials.host cStringUsingEncoding:_encoding];
    const char *user = [_credentials.username cStringUsingEncoding:_encoding];
    const char *pass = [_credentials.password cStringUsingEncoding:_encoding];
    netbuf *conn;
    int stat = FtpConnect(host, &conn);
    if (stat == 0) {
        // @fixme We don't get the exact error code from the lib. Use a generic
        // connection error.
        self.lastError = [NSError FTPKitErrorWithCode:10060];
        return NULL;
    }
    stat = FtpLogin(user, pass, conn);
    if (stat == 0) {
        NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        FtpQuit(conn);
        return NULL;
    }
    return conn;
}

- (BOOL)sendCommand:(NSString *)command conn:(netbuf *)conn
{
    const char *cmd = [command cStringUsingEncoding:_encoding];
    if (!FtpSendCmd(cmd, '2', conn)) {
        NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)failedWithMessage:(NSString *)message
{
    self.lastError = [NSError errorWithDomain:FTPErrorDomain
                                         code:502
                                     userInfo:[NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey]];
}

- (NSString *)temporaryUrl
{
    // Do not use NSURL. It will not allow you to read the file contents.
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FTPKit.list"];
    //FKLogDebug(@"path: %@", path);
    return path;
}

- (NSDictionary *)entryByReencodingNameInEntry:(NSDictionary *)entry encoding:(NSStringEncoding)newEncoding
{
    // Convert to the preferred encoding. By default CF encodes the string
    // as MacRoman.
    NSString *newName = nil;
    NSString *name = [entry objectForKey:(id)kCFFTPResourceName];
    if (name != nil) {
        NSData *data = [name dataUsingEncoding:_encoding]; //NSMacOSRomanStringEncoding];
        if (data != nil) {
            newName = [[NSString alloc] initWithData:data encoding:newEncoding];
        }
    }
    
    // If the above failed, just return the entry unmodified.  If it succeeded,
    // make a copy of the entry and replace the name with the new name that we
    // calculated.
    NSDictionary *result = nil;
    if (! newName) {
        result = (NSDictionary *)entry;
    } else {
        NSMutableDictionary *newEntry = [NSMutableDictionary dictionaryWithDictionary:entry];
        [newEntry setObject:newName forKey:(id)kCFFTPResourceName];
        result = newEntry;
    }
    return result;
}

/**
 `char` 포인터 기반으로 파싱 실행
 @param char 파싱할 char 포인터
 @param showHiddenFiles 감춤 파일 표시 여부
 @returns `FTPItem` 배열로 반환
 */
- (NSArray<FTPItem *> *)parseList:(char *)bufferData showHiddentFiles:(BOOL)showHiddenFiles
{
    if (bufferData == NULL ||
        strlen(bufferData) == 0) {
        return nil;
    }
    
    NSString *listString = [[NSString alloc] initWithCString:bufferData encoding:_encoding];
    if ([listString length] == 0) {
        return nil;
    }
    NSArray *lists = [listString componentsSeparatedByString:@"\n"];
    if ([lists count] == 0) {
        return nil;
    }
    
    NSMutableArray<FTPItem *> *parsedLists = [[NSMutableArray alloc] init];
    for (NSInteger i = 0; i < [lists count]; i++) {
        NSString *originLine = lists[i];
        if ([originLine length] == 0) {
            continue;
        }
        char *charLine = (char *)[originLine UTF8String];
        struct ftpparse *parsed = malloc(sizeof(struct ftpparse));
        int result = ftpparse(parsed, charLine, (int)strlen(charLine));
        // 파일명 발견시
        if (result == 1) {
            NSString *filename = [NSString stringWithCString:parsed->name encoding:_encoding];
            bool isHidden;
            // flagtryretr 가 true 또는 파일명이 . 으로 시작하는 경우 hidden file로 간주
            if (parsed->flagtryretr == true ||
                [filename hasPrefix:@"."] == true) {
                isHidden = true;
            }
            else {
                isHidden = false;
            }
            // showHiddenFiles == false 인데 감춤 파일인 경우 건너뛴다
            if (showHiddenFiles == false && isHidden == true) {
                continue;
            }

            // 추가 필요시
            bool isDir = parsed->flagtrycwd;
            long int size = parsed->size;
            NSDate *modificationDate = NULL;
            if (parsed->mtimetype != FTPPARSE_MTIME_UNKNOWN) {
                [NSDate dateWithTimeIntervalSince1970:parsed->mtime];
            }
            FTPItem *item = [[FTPItem alloc] initWithFilename:filename
                                                        isDir:isDir
                                                     isHidden:isHidden
                                                         size:size
                                             modificationDate:modificationDate];
            if (item != NULL) {
                [parsedLists addObject:item];
            }
        }
        // parse 해제
        free(parsed);
    }
    return parsedLists;
}

- (NSArray *)parseListData:(NSData *)data handle:(FTPHandle *)handle showHiddentFiles:(BOOL)showHiddenFiles
{
    NSMutableArray *files = [NSMutableArray array];
    NSUInteger offset = 0;
    do {
        CFDictionaryRef thisEntry = NULL;
        CFIndex bytes = CFFTPCreateParsedResourceListing(NULL, &((const uint8_t *) data.bytes)[offset], data.length - offset, &thisEntry);
        if (bytes > 0) {
            if (thisEntry != NULL) {
                NSDictionary *entry = [self entryByReencodingNameInEntry:(__bridge NSDictionary *)thisEntry encoding:_encoding];
                FTPHandle *ftpHandle = [FTPHandle handleAtPath:handle.path attributes:entry];
				if (! [ftpHandle.name hasPrefix:@"."] || showHiddenFiles) {
					[files addObject:ftpHandle];
				}
            }
            offset += bytes;
        }
        
        if (thisEntry != NULL) {
            CFRelease(thisEntry);
        }
        
        if (bytes == 0) {
            break;
        } else if (bytes < 0) {
            [self failedWithMessage:NSLocalizedString(@"Failed to parse directory listing", @"")];
            return nil;
        }
    } while (YES);
    
    if (offset != data.length) {
        FKLogWarn(@"Some bytes not read!");
    }
    
    return files;
}

- (NSDate *)lastModifiedAtPath:(NSString *)remotePath
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return nil;
    const char *cPath = [[self urlEncode:remotePath] cStringUsingEncoding:_encoding];
    char dt[kFTPKitRequestBufferSize];
    // This is returning FALSE when attempting to create a new folder that exists... why?
    // MDTM does not work with folders. It is meant to be used only for types
    // of files that can be downloaded using the RETR command.
    int stat = FtpModDate(cPath, dt, kFTPKitRequestBufferSize, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return nil;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    // FTP spec: YYYYMMDDhhmmss
    // @note dt always contains a trailing newline char.
    formatter.dateFormat = @"yyyyMMddHHmmss\n";
    NSString *dateString = [NSString stringWithCString:dt encoding:_encoding];
    NSDate *date = [formatter dateFromString:dateString];
    return date;
}

- (void)lastModifiedAtPath:(NSString *)remotePath success:(void (^)(NSDate *))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        NSDate *date = [self lastModifiedAtPath:remotePath];
        if (! self->_lastError && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(date);
            });
        } else if (self->_lastError && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)directoryExistsAtPath:(NSString *)remotePath
{
    /**
     Test the directory by changing to the directory. If the process succeeds
     then the directory exists.
     
     The process is to get the current working directory and change _back_ to
     the previous current working directory. There is a possibility that the
     second changeDirectoryToPath: may fail! This is really the price we pay
     for this command as there is no other accurate way to determine this.
     
     Using listContentsAtPath:showHiddenFiles: will fail as it will return empty
     contents even if the directory doesn't exist! So long as the command
     _succeeds_ it will return an empty list.
     
    // Get the current working directory. We will change back to this directory
    // if necessary.
    NSString *cwd = [self printWorkingDirectory];
    // No need to continue. We already know the path exists by the fact that we
    // are currently _in_ the directory.
    if ([cwd isEqualToString:remotePath])
        return YES;
    // Test directory by changing to it.
    BOOL success = [self changeDirectoryToPath:remotePath];
    // Attempt to change back to the previous directory.
    if (success)
        [self changeDirectoryToPath:cwd];
    return success;
     */
    
    /**
     Currently the lib creates a new connection for every command issued.
     Therefore, it is unnecessary to change back to the original cwd.
     */
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *cPath = [remotePath cStringUsingEncoding:_encoding];
    int stat = FtpChdir(cPath, conn);
    FtpQuit(conn);
    if (stat == 0)
        return NO;
    return YES;
}

- (void)directoryExistsAtPath:(NSString *)remotePath success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL exists = [self directoryExistsAtPath:remotePath];
        if (! self->_lastError && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(exists);
            });
        } else if (self->_lastError && failure) {
            [self returnFailureLastError:failure];
        }
    });
}

- (BOOL)changeDirectoryToPath:(NSString *)remotePath
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *cPath = [remotePath cStringUsingEncoding:_encoding];
    int stat = FtpChdir(cPath, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (NSString *)printWorkingDirectory
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return nil;
    char cPath[kFTPKitTempBufferSize];
    int stat = FtpPwd(cPath, kFTPKitTempBufferSize, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return nil;
    }
    return [NSString stringWithCString:cPath encoding:_encoding];
}

/**
 lastError를 에러 완료 핸들러로 반환
 */
- (void)returnFailureLastError:(void (^)(NSError * _Nonnull))failure
{
    NSError *error = [_lastError copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        failure(error);
    });
}
/**
 특정 에러를 에러 완료 핸들러로 반환
 */
- (void)returnFailure:(void (^)(NSError * _Nonnull))failure error:(NSError * _Nonnull)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        failure(error);
    });
}

@end
