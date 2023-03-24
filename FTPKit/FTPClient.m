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
- (netbuf * _Nullable)connect;

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
- (NSString * _Nonnull)temporaryPath;

/**
 Sets lastError w/ 'message' as description and error code 502.
 
 @param message Description to set to last error.
 */
- (void)failedWithMessage:(NSString * _Nonnull)message;

/**
 Convenience method that wraps failure(error) in dispatch_async(main_queue)
 and ensures that the error is copied before sending back to callee -- to ensure
 it doesn't get nil'ed out by the next command before the callee has a chance
 to read the error.
 */
- (void)returnFailureLastError:(void (^)(NSError * _Nonnull error))failure;

/**
 URL encode a path.
 
 This method is used only on _existing_ files on the FTP server.
 
 @param path The path to URL encode.
 */
- (NSString * _Nonnull)urlEncode:(NSString * _Nonnull)path;

@end

// MARK: - FTPClient Class -
@implementation FTPClient

// MARK: - Initialization
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

// MARK: - Internal Transfer Method
/**
 * 커맨드를 전송, 데이터를 포인터로 반환하는 메쏘드
 *
 * 파일 업로드 전용 메쏘드이며, 읽기 용도로 사용해선 안 된다
 *
 * @param fromPath 업로드할 로컬 파일 경로
 * @param fileSize 업로드할 파일 크기
 * @param remotePath FTP 파일 경로
 * @param savePath 다운로드 받은 파일을 저장할 경로
 * @param nControl netbuf
 * @param type 전송 타입
 * @param mode 전송 모드. 바이너리/아스키/이미지 중에서 선택.
 * @param completion 완료 핸들러. 실패시에는 NSError 값 반환.
 * @return NSProgress 반환. 해당 NSProgress를 이용, 중지 처리 가능. 접속 불가시 nil 반환
 */
- (NSProgress * _Nullable)ftpXferWriteFrom:(const char * _Nonnull)fromPath
                                      size:(long long int)fileSize
                                     toPath:(const char * _Nullable)remotePath
                                    control:(netbuf *)nControl
                                       mode:(int)mode
                                 completion:(void (^)(NSError * _Nullable error))completion
{
    
    FILE *local = NULL;

    // 파일 열기 시도
    char ac[4];
    memset( ac, 0, sizeof(ac) );
    ac[0] = 'r';
    if (mode == FTPLIB_IMAGE)
        ac[1] = 'b';
    local = fopen(fromPath, ac);
    // 로컬 파일을 여는데 실패한 경우 중지 처리
    if (local == NULL)
    {
        strncpy(nControl->response, strerror(errno),
                sizeof(nControl->response));
        // 파일 열기 실패로 처리
        completion([NSError FTPKitErrorWithCode:FTP_FailedToOpenFile]);
        return NULL;
    }

    // nData를 NULL로 선언
    netbuf *nData = NULL;
    if (!FtpAccess(remotePath, FTPLIB_FILE_WRITE, mode, 0, nControl, &nData))
    {
        // 실패시, 파일 입력 버퍼를 비우고 닫는다
        if (local != NULL)
        {
            if (nData != NULL)
                free(nData);
            fclose(local);
            unlink(fromPath);
        }
        // 접속 실패로 처리
        completion([NSError FTPKitErrorWithCode:FTP_CannotConnectToServer]);
        return NULL;
    }

    NSProgress *progress = [[NSProgress alloc] init];
    [progress setTotalUnitCount:fileSize];
    
    // 백그라운드 큐에서 실행
    dispatch_async(_queue, ^{

        // 작업 실패 여부
        bool wasFailed = false;
        // 작업 강제 중지 여부
        bool wasAborted = false;

        int input = 0;
        int write = 0;

        // 버퍼 초기화
        char *dbuf = malloc(FTPLIB_BUFSIZ);
        // 전송된 파일 길이
        long long int progressed = 0;

        while ((input = (int)fread(dbuf, 1, FTPLIB_BUFSIZ, local)) > 0)
        {
            if ([progress isCancelled] == true)
            {
                wasFailed = true;
                wasAborted = true;
                [self stopOperation:nControl];
                break;
            }
            
            if ((write = FtpWrite(dbuf, input, nData)) < input)
            {
                printf("short write: passed %d, wrote %d\n", input, write);
                wasFailed = true;
                break;
            }
            
            // 완료 갯수 업데이트
            progressed += FTPLIB_BUFSIZ;
            if (progressed > fileSize)
                progressed = fileSize;
            [progress setCompletedUnitCount:progressed];
            
            NSLog(@"전송률 = %f", progress.fractionCompleted);
        }

        // nData 를 닫는다
        FtpClose(nData);

        // 실패
        if (wasFailed == true)
        {
            int errorCode = wasAborted == true ? FTP_Aborted : FTP_FailedToUploadFile;
            completion([NSError FTPKitErrorWithCode:errorCode]);
        }
        // 성공
        else
            completion(nil);
        
        // dbuf 해제
        if (dbuf != NULL)
            free(dbuf);

        // 파일 입력 버퍼를 비우고 닫는다
        if (local != NULL)
        {
            fclose(local);
            unlink(fromPath);
        }
    });
    
    return progress;
}
/**
 * 커맨드를 전송, 데이터를 포인터로 반환하는 메쏘드
 *
 * 데이터 / 디렉토리 읽기 전용 메쏘드이며, 쓰기 용도로 사용해선 안 된다
 *
 * @param remotePath FTP 파일 경로
 * @param savePath 다운로드 받은 파일을 저장할 경로. 직접 NSData로 받고자 하는 경우는 NULL로 지정
 * @param offset 다운로드 시작점. 불필요시 0으로 지정
 * @param length 다운로드 받을 길이. 불필요시 0으로 지정
 * @param nControl netbuf
 * @param type 전송 타입
 * @param mode 전송 모드. 바이너리/아스키/이미지 중에서 선택.
 * @param completion 완료 핸들러. 데이터 형식으로 다운로드하는 경우, 성공시 NSData 반환. 실패시에는 NSError 값 반환.
 * @return NSProgress 반환. 해당 NSProgress를 이용, 중지 처리 가능. 접속 불가시 nil 반환
 */
- (NSProgress * _Nullable)ftpXferReadDataFrom:(const char * _Nonnull)remotePath
                                       toPath:(const char * _Nullable)savePath
                                       offset:(long long int)offset
                                       length:(long long int)length
                                      control:(netbuf *)nControl
                                         type:(int)type
                                         mode:(int)mode
                                   completion:(void (^)(NSData * _Nullable data,
                                                        NSError * _Nullable error))completion
{
    // 파일 읽기 또는 디렉토리 읽기 동작이 아닌 경우 NULL 반환
    if (type != FTPLIB_FILE_READ &&
        type != FTPLIB_FILE_READ_OFFSET &&
        type != FTPLIB_DIR &&
        type != FTPLIB_DIR_VERBOSE)
        // 잘못된 작업 지정
        completion(NULL, [NSError FTPKitErrorWithCode:FTP_AccessWrongType]);
        return NULL;;
    
    // 데이터 읽기 작업인지 여부
    BOOL isReadData = false;
    if (type == FTPLIB_FILE_READ ||
        type == FTPLIB_FILE_READ_OFFSET)
    {
        isReadData = true;
    }
    
    long long int fullLength = -1;
    
    // 데이터 파일을 읽는 경우는 fullLength를 파일 크기로 지정
    // 디렉토리 읽기는 -1 유지
    if (isReadData) {
        if (length <= 0)
            fullLength = [self fileSizeAt:remotePath];
        else
            fullLength = length;
        
        // 전체 크기가 0 또는 그보다 작은 경우 중지 처리
        if (fullLength <= 0)
        {
            completion(NULL, [NSError FTPKitErrorWithCode:FTP_FailedToReadByWrongSize]);
            return NULL;
        }
        // offset 이 전체 크기보다 큰 경우도 중지 처리
        if (offset > fullLength)
        {
            completion(NULL, [NSError FTPKitErrorWithCode:FTP_FailedToReadByWrongSize]);
            return NULL;
        }
        // 다운로드 길이가 정해진 경우
        if (length > 0)
        {
            if (fullLength - (offset + length) < 0)
                // 다운로드 가능한 길이를 변경 처리
                length = fullLength - offset;
        }
    }
    
    // 로컬 저장용 포인터
    FILE *local = NULL;
    // 파일 저장 경로가 주어진 경우
    if (savePath != NULL)
    {
        char ac[4];
        memset( ac, 0, sizeof(ac) );
        ac[0] = 'w';
        if (mode == FTPLIB_IMAGE)
            ac[1] = 'b';
        local = fopen(savePath, ac);
        if (local == NULL)
        {
            strncpy(nControl->response, strerror(errno),
                    sizeof(nControl->response));
            // 파일 열기에 실패
            completion(NULL, [NSError FTPKitErrorWithCode:FTP_FailedToOpenFile]);
            return NULL;
        }
    }
    
    // nData를 NULL로 선언
    netbuf *nData = NULL;
    if (!FtpAccess(remotePath, type, mode, offset, nControl, &nData))
    {
        // 실패시, 파일 출력 버퍼를 비우고 닫는다
        if (local != NULL)
        {
            if (nData != NULL)
                free(nData);
            fflush(local);
            if (savePath != NULL)
                fclose(local);
        }
        // 접속 실패
        completion(NULL, [NSError FTPKitErrorWithCode:FTP_CannotConnectToServer]);
        return NULL;
    }
    
    NSProgress *progress = [[NSProgress alloc] init];
    [progress setTotalUnitCount:fullLength];

    // 백그라운드 큐에서 실행
    dispatch_async(_queue, ^{
        // 파일 경로 저장 길이
        NSInteger saveLength = 0;
        
        // 다운로드 버퍼 초기화
        char *dbuf = malloc(FTPLIB_BUFSIZ);
        // 버퍼 초기화
        char *bufferData = NULL;
        // 버퍼 타겟 사이즈
        long long int bufferDataSize = 0;
        if (isReadData == true)
        {
            // 마지막 널값 처리를 위해 totalUnitCount 값에 1을 더한다
            bufferDataSize = fullLength + 1;
            // 버퍼 크기보다 큰 경우, 버퍼 크기로 재조정
            if (FTPLIB_BUFFER_LENGTH < bufferDataSize)
                bufferDataSize = FTPLIB_BUFFER_LENGTH;
            bufferData = (char *)malloc(bufferDataSize);
        }
        else
        {
            bufferDataSize = sizeof(char) * FTPLIB_BUFFER_LENGTH;
            bufferData = (char *)malloc(bufferDataSize);
        }
        
        // 작업 실패 여부
        bool wasFailed = false;
        // 작업 강제 중지 여부
        bool wasAborted = false;
        // 전송 길이 도달 여부
        bool isEndOfFile = false;
        
        // 전송된 파일 길이
        long long int progressed = 0;

        while ((saveLength = FtpRead(dbuf, FTPLIB_BUFSIZ, nData)) > 0)
        {
            // progress 중지 발생시
            if ([progress isCancelled] == true)
            {
                wasFailed = true;
                wasAborted = true;
                // 작업 중지 처리
                [self stopOperation:nControl];
                break;
            }

            // 예상 총 용량
            long long int totalLength = progressed + FTPLIB_BUFSIZ;

            // 파일 읽기가 아닌 경우
            // 즉, 디렉토리 읽기인 경우, bufferData의 메모리 증가가 필요한지 확인 필요
            if (isReadData == false)
            {
                // 현재 저장 공간에 dbuf를 추가한 경우, 메모리 증가가 필요한지 여부를 확인
                int multiple = ((int)totalLength / FTPLIB_BUFFER_LENGTH) + 1;
                if (bufferDataSize < multiple * FTPLIB_BUFFER_LENGTH)
                {
                    // 메모리 증대 필요시
                    // realloc 실행
                    // https://woo-dev.tistory.com/124
                    char *tempBuffer = bufferData;
                    // 마지막 널값 처리를 위해 multiple 값에 1을 더한다
                    bufferDataSize = (multiple * FTPLIB_BUFFER_LENGTH) + 1;
                    bufferData = (char *)realloc(bufferData, bufferDataSize);
                    if (bufferData == NULL) {
                        // 실패시 기존 포인터를 해제하고 중지 처리
                        wasFailed = true;
                        free(tempBuffer);
                        // 작업 중지 처리
                        [self stopOperation:nControl];
                        break;
                    }
                }
            }
            
            // 파일 읽기인 경우
            // 정해진 length 가 있는 경우
            if (isReadData == true &&
                length > 0)
            {
                // totalLength 가 정해진 length 초과
                if (totalLength >= length)
                {
                    // 저장 길이 변경
                    saveLength = length - progressed;
                    isEndOfFile = true;
#if DEBUG
                    if (saveLength <= 0) {
                        NSLog(@"저장 가능한 길이가 0 이하. 더 이상의 저장은 불가능");
                    }
#endif
                }
            }
            
            // 파일 저장시
            if (savePath != NULL &&
                saveLength > 0)
            {
                if (fwrite(dbuf, 1, saveLength, local) == 0)
                    wasFailed = true;
            }
            // 데이터 반환시
            else
            {
                // bufferData에 dbuf를 추가
                if (strncat(bufferData, dbuf, saveLength) == NULL)
                    wasFailed = true;
            }
            
            // progressed에 현재 버퍼의 길이 추가
            progressed += FTPLIB_BUFSIZ;
            // 데이터 파일을 읽는 경우는 진행상태 업데이트
            if (isReadData)
                [progress setCompletedUnitCount:progressed];

            // 실패 발생시
            if (wasFailed == true)
            {
                // 추가 실패시
                if (ftplib_debug)
                    perror("data read error");
                // 실패 처리 필요
                wasFailed = true;
                // 정해진 길이 초과시, 중지 처리까지 선언한다
                if (isEndOfFile == true)
                    wasAborted = true;
                // 작업 중지 처리
                [self stopOperation:nControl];
                break;
            }
            
            // 전송 길이 도달 여부 발생시 (전체 길이가 정해진 길이를 초과한 경우이므로 중지)
            if (isEndOfFile == true)
            {
                wasAborted = true;
                // 작업 중지 처리
                [self stopOperation:nControl];
                break;
            }
        }

//        if (wasAborted == true)
//            // 사용자 중지 발생시, FtpAccess에서 중지 처리
//            FtpAccess(remotePath, FTPLIB_ABORT, FTPLIB_BINARY, 0, nControl, NULL);
        
        // nData 를 닫는다
        FtpClose(nData);

        // 완료 핸들러 실행 및 종료 처리를 진행
        
        // 파일 경로 저장시
        if (savePath != NULL)
        {
            int resultCode = FTP_Success;
            if (wasFailed == true) {
                resultCode = FTP_FailedToReadByUnknown;
            }
            else
            {
                NSFileManager *fileManager = [NSFileManager defaultManager];
                // 저장 경로는 UTF8로 인코딩해서 생성
                NSString *savedPath = [NSString stringWithCString:savePath encoding:NSUTF8StringEncoding];
                if ([fileManager fileExistsAtPath:savedPath] == false)
                    // 파일이 없는 경우 실패 처리
                    resultCode = FTP_FailedToSaveToLocal;
                // 이유는 불확실하지만, 이 시점에서 NSFileManager로 파일 크기 확인이 불가능하므로, 존재 여부만 확인하도록 한다
            }

            // 성공시
            if (resultCode == FTP_Success)
                completion(NULL, NULL);
            // 실패시
            else
                completion(NULL, [NSError FTPKitErrorWithCode:resultCode]);
        }
        // 데이터 반환시
        else
        {
            // 실패
            // 또는 bufferData가 NIL인 경우
            if (wasFailed == true ||
                bufferData == NULL)
            {
                int errorCode = wasAborted == true ? FTP_Aborted : FTP_FailedToReadByUnknown;
                completion(NULL, [NSError FTPKitErrorWithCode:errorCode]);
            }
            // 파일 데이터 읽기시
            // 또는 bufferData가 있는 경우
            else
            {
                // 데이터 파일을 읽는 경우, totalUnitCount에 맞춰서 데이터 생성
                if (isReadData) {
                    if (fullLength <= progressed)
                        completion([[NSData alloc] initWithBytes:bufferData length:fullLength], NULL);
                    else
                    {
                        // 용량 불일치로 다운로드 실패
                        NSError *error = [NSError FTPKitErrorWithCode:FTP_FailedToReadByIncomplete];
                        completion(NULL, error);
                    }
                }
                // 아닌 경우 - 디렉토리를 읽는 경우
                else
                {
                    if (progressed <= 0)
                    {
                        // 데이터 길이가 0인 경우
                        NSError *error = [NSError FTPKitErrorWithCode:FTP_FailedToReadByUnknown];
                        completion(NULL, error);
                    }
                    else
                        completion([[NSData alloc] initWithBytes:bufferData length:progressed], NULL);
                }
            }
        }
        
        // dbuf 해제
        if (dbuf != NULL)
            free(dbuf);

        // 버퍼 해제
        if (bufferData != NULL)
            free(bufferData);
        
        // 파일 출력 버퍼를 비우고 닫는다
        if (local != NULL)
        {
            fflush(local);
            if (savePath != NULL)
                fclose(local);
        }
    });
    
    // Progress 반환
    return progress;
}

// MARK: - Methods

- (NSString *)urlEncode:(NSString *)path
{
    return [path stringByRemovingPercentEncoding];
    //return [path stringByReplacingPercentEscapesUsingEncoding:_encoding];
}

/// 로컬 파일 크기 구하기.
- (long long int)localFileSizeAtPath:(NSString *)path
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:path] == false) {
        return 0;
    }
    NSError *error = NULL;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
    if (error != NULL) {
        NSLog(@"Error = %@", [error description]);
        return 0;
    }
    return [[fileAttributes objectForKey:NSFileSize] longLongValue];
}
/// FTP 파일 크기 구하기.
- (long long int)fileSizeAtPath:(NSString *)path
{
    const char *cPath = [[self urlEncode:path] cStringUsingEncoding:_encoding];
    return [self fileSizeAt:cPath];
}
/**
 실제 서버 상의 파일 크기 확인 메쏘드
 
 @param path `const char` 포인터 타입의 경로
 @returns 64비트 정수형으로 크기 반환. 실패시 -1 반환
 */
- (long long int)fileSizeAt:(const char * _Nonnull)path
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return -1;
    unsigned int bytes;
    int stat = FtpSize(path, &bytes, FTPLIB_BINARY, conn);
    FtpQuit(conn);
    if (stat == 0) {
        FKLogError(@"File most likely does not exist %@", [NSString stringWithCString:path encoding:_encoding]);
        return -1;
    }
    FKLogDebug(@"%@ bytes %d", [NSString stringWithCString:path encoding:_encoding], bytes);
    return (long long int)bytes;
}

/**
 특정 Connection의 FTP 작업 중지
 
 @returns 결과를 true / false 로 반환
 */
- (BOOL)stopOperation:(netbuf * _Nullable)conn {
    if (conn == NULL)
        return false;
    NSString *command = [NSString stringWithFormat:@"ABOR"];
    BOOL success = [self sendCommand:command conn:conn];

    if (!success) {
        return false;
    }
    return true;
}
/**
 특정 Connection의 FTP 작업 중지
 
 백그라운드 쓰레드로 중지 처리
 
 @returns 결과를 완료 핸들러로 반환
 */
- (void)stopOperation:(netbuf * _Nullable)conn
           completion:(void (^ _Nonnull)(bool success))completion
{
    if (conn == NULL) {
        completion(false);
        return;
    }
    NSString *command = [NSString stringWithFormat:@"ABOR"];
    BOOL success = [self sendCommand:command conn:conn];

    if (success) {
        completion(true);
    }
    else {
        completion(false);
    }
}

/**
 목록을 가져오는 메쏘드
 
 - 반환된 NSProgress를 이용해 작업 취소 가능
 
 @param remotePath 목록을 가져올 경로
 @param showHiddenFiles 감춤 파일 표시 여부
 @param completion 완료 핸들러로 읽어들인 FTPItem 배열 반환. 실패시 error 값이 반환.
 @return NSProgress 반환. 실패시 NULL 반환.
 */
- (NSProgress * _Nullable)listContentsAtPath:(NSString * _Nonnull)remotePath
                             showHiddenFiles:(BOOL)showHiddenFiles
                                  completion:(void (^ _Nonnull)(NSArray<FTPItem *> * _Nullable items, NSError * _Nullable error))completion
{
    netbuf *conn = [self connect];
    const char *path = [[self urlEncode:remotePath] cStringUsingEncoding:_encoding];
    
    NSProgress *progress = [self ftpXferReadDataFrom:path
                                              toPath:NULL
                                              offset:0
                                              length:0
                                             control:conn
                                                type:FTPLIB_DIR_VERBOSE
                                                mode:FTPLIB_ASCII
                                          completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        if (error != NULL) {
            // 에러 발생시, 그대로 에러 반환
            completion(NULL, error);
        }
        else
        {
            NSArray *items = [self parseListFromData:data showHiddentFiles:showHiddenFiles];
            if (items == NULL ||
                [items count] == 0) {
                NSError *error = [NSError FTPKitErrorWithCode:FTP_FailedToReadByUnknown];
                completion(NULL, error);
            }
            else
                completion(items, error);
        }
        // 접속 종료
        FtpQuit(conn);
    }];
    // progress 생성 실패시
    if (progress == NULL) {
        // 완료 핸들러 종료
        NSError *error = [NSError FTPKitErrorWithCode:FTP_CannotConnectToServer];
        completion(NULL, error);
        return NULL;
    }
    return progress;
}

/**
 FTP 경로에서 데이터를 파일로 다운로드.
 
 - 전체 파일을 특정 경로로 다운로드
 - 반환된 NSProgress를 이용해 작업 취소 가능

 @param remotePath Full path of remote file to download.
 @param savePath 다운로드 받은 파일을 저장할 경로.
 @param completion 완료 핸들러. 실패시 error 반환.
 @return NSProgress 반환. 실패시 NULL 반환
 */
- (NSProgress * _Nullable)downloadFile:(NSString * _Nonnull)remotePath
                            toSavePath:(NSString * _Nonnull)savePath
                            completion:(void (^ _Nonnull)(NSError * _Nullable error))completion
{
    return [self downloadFile:remotePath
                   toSavePath:savePath
                       offset:0
                       length:0
                   completion:completion];
}
/**
 FTP 경로에서 offset/length를 지정해 필요한 만큼의 데이터를 파일로 다운로드.
 
 - 파일 일부를 특정 경로로 다운로드
 - 반환된 NSProgress를 이용해 작업 취소 가능

 @param remotePath Full path of remote file to download.
 @param offset 다운로드를 시작할 offset 위치. 처음부터 다운로드시 0 지정
 @param length 다운로드 받을 길이. 전체 다운로드시 0 지정
 @param completion 완료 핸들러. 성공시 data 반환. 실패시 error 반환.
 @return NSProgress 반환. 실패시 NULL 반환
 */
- (NSProgress * _Nullable)downloadFile:(NSString * _Nonnull)remotePath
                            toSavePath:(NSString * _Nonnull)savePath
                                offset:(long long int)offset
                                length:(long long int)length
                            completion:(void (^ _Nonnull)(NSError * _Nullable error))completion
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NULL;
        
    const char *path = [[self urlEncode:remotePath] cStringUsingEncoding:self.encoding];
    const char *saveFilePath = [savePath cStringUsingEncoding:_encoding];
    if (path == NULL ||
        saveFilePath == NULL)
        return NULL;
    
    int type = FTPLIB_FILE_READ;
    if (offset > 0) {
        type = FTPLIB_FILE_READ_OFFSET;
    }
    
    NSProgress *progress = [self ftpXferReadDataFrom:path
                                            toPath:saveFilePath
                                            offset:offset
                                            length:length
                                           control:conn
                                              type:type
                                              mode:FTPLIB_BINARY
                                        completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        if (error != NULL)
        {
            // 에러 발생시
            // 이미 생성된 파일이 있는 경우 제거 처리
            NSFileManager *fileManager = [NSFileManager defaultManager];
            if ([fileManager fileExistsAtPath:savePath])
                [fileManager removeItemAtPath:savePath error:NULL];
        }
        
        completion(error);
        FtpQuit(conn);
    }];

    if (progress == NULL)
    {
        // 완료 핸들러 종료
        NSError *error = [NSError FTPKitErrorWithCode:FTP_CannotConnectToServer];
        completion(error);
        return NULL;
    }
    return progress;
}
/**
 FTP 경로에서 데이터 다운로드.
 
 - 전체 파일을 데이터로 다운로드
 - 반환된 NSProgress를 이용해 작업 취소 가능

 @param remotePath Full path of remote file to download.
 @param completion 완료 핸들러. 성공시 data 반환. 실패시 error 반환.
 @return NSProgress 반환. 실패시 NULL 반환
 */
- (NSProgress * _Nullable)downloadFile:(NSString * _Nonnull)remotePath
                            completion:(void (^ _Nonnull)(NSData * _Nullable data,
                                                          NSError * _Nullable error))completion
{
    return [self downloadFile:remotePath
                       offset:0
                       length:0
                   completion:completion];
}
/**
 FTP 경로에서 offset/length를 지정해 필요한 만큼의 데이터 다운로드.
 
 - 반환된 NSProgress를 이용해 작업 취소 가능

 @param remotePath Full path of remote file to download.
 @param offset 다운로드를 시작할 offset 위치. 처음부터 다운로드시 0 지정
 @param length 다운로드 받을 길이. 전체 다운로드시 0 지정
 @param completion 완료 핸들러. 성공시 data 반환. 실패시 error 반환.
 @return NSProgress 반환. 실패시 NULL 반환
 */
- (NSProgress * _Nullable)downloadFile:(NSString * _Nonnull)remotePath
                                offset:(long long int)offset
                                length:(long long int)length
                            completion:(void (^ _Nonnull)(NSData * _Nullable data,
                                                          NSError * _Nullable error))completion
{
    netbuf *conn = [self connect];
    if (conn == NULL)
    {
        // 접속 실패
        completion(NULL, [NSError FTPKitErrorWithCode:FTP_CannotConnectToServer]);
        return NULL;
    }
    
    const char *path = [[self urlEncode:remotePath] cStringUsingEncoding:self.encoding];
    if (path == NULL)
    {
        // 접속 실패
        completion(NULL, [NSError FTPKitErrorWithCode:FTP_FailedToOpenFile]);
        return NULL;
    }
    
    int type = FTPLIB_FILE_READ;
    if (offset > 0) {
        type = FTPLIB_FILE_READ_OFFSET;
    }
    NSProgress *progress = [self ftpXferReadDataFrom:path
                                              toPath:NULL
                                              offset:offset
                                              length:length
                                             control:conn
                                                type:type
                                                mode:FTPLIB_BINARY
                                          completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        completion(data, error);
        FtpQuit(conn);
    }];
    
    if (progress == NULL)
    {
        // 완료 핸들러 종료
        completion(NULL, [NSError FTPKitErrorWithCode:FTP_CannotConnectToServer]);
        return NULL;
    }
    return progress;
}

/**
 로컬 파일을 지정된 FTP 경로로 업로드.
 
 - 반환된 NSProgress를 이용해 작업 취소 가능

 @param localPath 업로드할 로컬 파일 경로.
 @param remotePath 업로드할 FTP 경로.
 @param completion 완료 핸들러. 실패시 error 반환.
 @return NSProgress 반환. 실패시 NULL 반환
 */
- (NSProgress * _Nullable)uploadFileFrom:(NSString * _Nonnull)localPath
                                      to:(NSString * _Nonnull)remotePath
                              completion:(void (^ _Nonnull)(NSError * _Nullable error))completion
{
    netbuf *conn = [self connect];
    if (conn == NULL)
    {
        // 접속 실패
        completion([NSError FTPKitErrorWithCode:FTP_CannotConnectToServer]);
        return NULL;
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:localPath] == false)
    {
        // 파일 열기 실패
        completion([NSError FTPKitErrorWithCode:FTP_FailedToOpenFile]);
        return NULL;
    }

    long long int fileSize = [self localFileSizeAtPath:localPath];
    if (fileSize == 0)
    {
        completion([NSError FTPKitErrorWithCode:FTP_ZeroFileSize]);
        return NULL;
    }
    
    const char *fromLocalPath = [[self urlEncode:localPath] cStringUsingEncoding:NSUTF8StringEncoding];
    const char *toSavePath = [[self urlEncode:remotePath] cStringUsingEncoding:_encoding];
    
    NSProgress *progress = [self ftpXferWriteFrom:fromLocalPath
                                             size:fileSize
                                           toPath:toSavePath
                                          control:conn
                                             mode:FTPLIB_BINARY
                                       completion:^(NSError * _Nullable error) {
        completion(error);
        FtpQuit(conn);
    }];
    
    if (progress == NULL)
    {
        // 완료 핸들러 종료
        completion([NSError FTPKitErrorWithCode:FTP_CannotConnectToServer]);
        return NULL;
    }
    return progress;
}
/*
- (BOOL)uploadFile:(NSString *)localPath to:(NSString *)remotePath progress:(BOOL (^)(NSUInteger, NSUInteger))progress
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *input = [localPath cStringUsingEncoding:NSUTF8StringEncoding];
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
*/
- (BOOL)createDirectoryAtPath:(NSString *)remotePath
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *path = [remotePath cStringUsingEncoding:_encoding];
    int stat = FtpMkdir(path, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
}

- (void)createDirectoryAtPath:(NSString *)remotePath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self createDirectoryAtPath:remotePath];
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
    return [self deleteItemAtPath:remotePath isFile:false];
    //return [self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeDirectory]];
}

- (void)deleteDirectoryAtPath:(NSString *)remotePath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    [self deleteItemAtPath:remotePath isFile:false success:success failure:failure];
    //[self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeDirectory] success:success failure:failure];
}

- (BOOL)deleteFileAtPath:(NSString *)remotePath
{
    return [self deleteItemAtPath:remotePath isFile:true];
    //return [self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeFile]];
}

- (void)deleteFileAtPath:(NSString *)remotePath success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    [self deleteItemAtPath:remotePath isFile:true success:success failure:failure];
    //[self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeFile] success:success failure:failure];
}

/**
 실제 제거 작업 실행 메쏘드
 
 @param remotePath 제거할 아이템 경로
 @param isFile true 인 경우는 파일, false 는 디렉토리 제거로 판정
 @returns 제거 성공 여부
 */
- (BOOL)deleteItemAtPath:(NSString * _Nonnull)remotePath isFile:(BOOL)isFile
{
    netbuf *conn = [self connect];
    if (conn == NULL)
        return NO;
    const char *path = [[self urlEncode:remotePath] cStringUsingEncoding:_encoding];
    int stat = 0;
    // 파일인 경우
    if (isFile)
        stat = FtpDelete(path, conn);
    // 디렉토리인 경우
    else
        stat = FtpRmdir(path, conn);
    NSString *response = [NSString stringWithCString:FtpLastResponse(conn) encoding:_encoding];
    FtpQuit(conn);
    if (stat == 0) {
        self.lastError = [NSError FTPKitErrorWithResponse:response];
        return NO;
    }
    return YES;
    //return [self deleteHandle:[FTPHandle handleAtPath:remotePath type:FTPHandleTypeDirectory]];
}
/**
 실제 제거 작업 백그라운드 실행 메쏘드
 
 @param remotePath 제거할 아이템 경로
 @param isFile true 인 경우는 파일, false 는 디렉토리 제거로 판정
 @param success 성공시 완료 핸들러
 @param failure 실패시 완료 핸들러
 */
- (void)deleteItemAtPath:(NSString * _Nonnull)remotePath
                  isFile:(BOOL)isFile
                 success:(void (^)(void))success
                 failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self deleteItemAtPath:remotePath isFile:isFile];
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
    if (mode < 0 || mode > 777) {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:NSLocalizedString(@"File mode value must be between 0 and 0777.", @"")
                                                             forKey:NSLocalizedDescriptionKey];
        self.lastError = [[NSError alloc] initWithDomain:FTPErrorDomain code:0 userInfo:userInfo];
        return NO;
    }
    NSString *command = [NSString stringWithFormat:@"SITE CHMOD %i %@", mode, [self urlEncode:remotePath]];
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

- (void)chmodPath:(NSString *)remotePath toMode:(int)mode success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    dispatch_async(_queue, ^{
        BOOL ret = [self chmodPath:remotePath toMode:mode];
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

- (NSString *)temporaryPath
{
    // Do not use NSURL. It will not allow you to read the file contents.
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FTPKit.list"];
    //FKLogDebug(@"path: %@", path);
    return path;
}

/**
 `char` 포인터 기반으로 파싱 실행
 @param char 파싱할 char 포인터
 @param showHiddenFiles 감춤 파일 표시 여부
 @returns `FTPItem` 배열로 반환
 */
- (NSArray<FTPItem *> *_Nullable)parseListFromBuffer:(char * _Nullable)bufferData showHiddentFiles:(BOOL)showHiddenFiles
{
    if (bufferData == NULL ||
        strlen(bufferData) == 0) {
        return nil;
    }
    
    NSString *listString = [[NSString alloc] initWithCString:bufferData encoding:_encoding];
    if ([listString length] == 0) {
        return nil;
    }
    return [self parseListFromLists:listString showHiddentFiles:showHiddenFiles];
}
/**
 `NSData` 기반으로 파싱 실행
 @param data 파싱할 NSData
 @param showHiddenFiles 감춤 파일 표시 여부
 @returns `FTPItem` 배열로 반환
 */
- (NSArray<FTPItem *> *_Nullable)parseListFromData:(NSData * _Nullable)data showHiddentFiles:(BOOL)showHiddenFiles
{
    if (data == NULL ||
        [data length] == 0) {
        return nil;
    }

    NSString *listString = [[NSString alloc] initWithData:data encoding:_encoding];
    return [self parseListFromLists:listString showHiddentFiles:showHiddenFiles];
}

/**
 `NSString` 기반으로 파싱 실행
 @param listString 파싱할 리스트 목록이 격납된 NSString
 @param showHiddenFiles 감춤 파일 표시 여부
 @returns `FTPItem` 배열로 반환
 */
- (NSArray<FTPItem *> * _Nullable)parseListFromLists:(NSString * _Nonnull)listString showHiddentFiles:(BOOL)showHiddenFiles
{
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
            // 파일명이 . 으로 시작하는 경우 hidden file로 간주
            if ([filename hasPrefix:@"."] == true)
                isHidden = true;
            else
                isHidden = false;

            // showHiddenFiles == false 인데 감춤 파일인 경우 건너뛴다
            if (showHiddenFiles == false && isHidden == true)
                continue;

            // 추가 필요시
            bool isDir = parsed->flagtrycwd;
            long int size = parsed->size;
            NSDate *modificationDate = NULL;
            if (parsed->mtimetype != FTPPARSE_MTIME_UNKNOWN)
                [NSDate dateWithTimeIntervalSince1970:parsed->mtime];

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
