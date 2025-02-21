//
//  FTPKit_Tests.m
//  FTPKit Tests
//
//  Created by Eric Chamberlain on 3/7/14.
//  Copyright (c) 2014 Upstart Illustration LLC. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "FTPKit.h"
#import "FTPKit+Protected.h"
#import "NSDate+NSDate_Additions.h"

@interface FTPKit_Tests : XCTestCase

@end

@implementation FTPKit_Tests

- (void)setUp
{
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testNSError
{
    
}

- (void)testNSURL
{
    
}

- (void)testFtp
{
    FTPClient * ftp = [[FTPClient alloc] initWithHost:@"djhan.asuscomm.com"
                                                 port:21
                                             encoding: NSUTF8StringEncoding
                                             username:@"djhan"
                                             password:@"shakamuth837"];
    
    // Sanity. Make sure the root path exists. This should always be true.
    NSError *error;
    BOOL success = [ftp directoryExistsAtPath:@"0.Privates" error:&error];
    NSLog(@"error = %li, %@", [error code], [error description]);
    XCTAssertTrue(success, @"");
    
    XCTestExpectation *expectationDir = [self expectationWithDescription:@"Read Directory..."];

    NSProgress *listingProgress = [ftp listContentsAtPath:@"0.Privates"
                                          showHiddenFiles:true
                                               completion:^(NSArray<FTPItem *> * _Nullable items, NSError * _Nullable error) {
        if (error != NULL) {
            NSLog(@"리스팅 실패. error code = %li", error.code);
        }
        else {
            for (NSInteger i = 0; i < [items count]; i++) {
                FTPItem *item = items[i];
                NSLog(@"%@ (%@), %hhd, %hhd\n", [item filename], [[item modificationDate] string], [item isDir], [item isHidden]);
            }
        }
        [expectationDir fulfill];
    }];
    [self waitForExpectations:@[expectationDir] timeout:3];
    
    XCTestExpectation *expectationDownload = [self expectationWithDescription:@"Download File..."];

    NSProgress *downloadProgress = [ftp downloadFile:@"/0.Privates/exr.zip"
                                          toSavePath:@"/Users/djhan/Desktop/exr.zip"
                                              offset:0
                                              length:1024
                                          completion:^(NSError * _Nullable error) {
//    NSProgress *downloadProgress = [ftp downloadFile:@"/0.Privates/exr.zip"
//                                              offset:0
//                                              length:1024
//                                          completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        if (error != NULL) {
            NSLog(@"다운로드 실패. error code = %li", error.code);
        }
//        else {
//            NSLog(@"data size = %lu", [data length]);
//            NSURL *url = [[NSURL alloc] initFileURLWithPath:@"/Users/djhan/Desktop/exr.zip"];
//            [data writeToURL:url atomically:true];
//        }
        [expectationDownload fulfill];
    }];
    
    [self waitForExpectations:@[expectationDownload] timeout:10];
    
    XCTestExpectation *expectationUpload = [self expectationWithDescription:@"Upload File..."];

    NSProgress *uploadProgress = [ftp uploadFileFrom:@"/Volumes/Data/test.7z"
                                                  to:@"/0.Privates/test_up.7z"
                                          completion:^(NSError * _Nullable error) {
        if (error != NULL) {
            NSLog(@"업로드 실패. error code = %li", error.code);
        }
        [expectationUpload fulfill];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (uploadProgress != NULL) {
            NSLog(@"업로드 중지...");
            [uploadProgress cancel];
        }
    });
    
    [self waitForExpectations:@[expectationUpload] timeout:30];

    return;

//    bytes = [ftp fileSizeAtPath:@"/copy.tgz"];
//    XCTAssertEqual(-1, -1, @"");
//
//    // Create 'test1.txt' file to upload. Contents are 'testing 1'.
//    NSURL *localUrl = [[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:@"ftplib.tgz"];
//
//    // Download 'ftplib.tgz'
//    success = [ftp downloadFile:@"/0.Privates/exr.zip" to:localUrl.path progress:NULL];
//    XCTAssertTrue(success, @"");
//
//    // Upload 'ftplib.tgz' as 'copy.tgz'
//    success = [ftp uploadFile:localUrl.path to:@"/copy.tgz" progress:NULL];
//    XCTAssertTrue(success, @"");
//
//    // chmod 'copy.tgz' to 777
//    success = [ftp chmodPath:@"/copy.tgz" toMode:777];
//    XCTAssertTrue(success, @"");
//
//    // Create directory 'test'
//    success = [ftp createDirectoryAtPath:@"/test"];
//    XCTAssertTrue(success, @"");
//
//    NSDate *date = [ftp lastModifiedAtPath:@"/ftplib.tgz"];
//    NSLog(@"date %@", date);
//    XCTAssertNotNil(date, @"");
//    // @todo
//
//    BOOL exists = [ftp directoryExistsAtPath:@"/test"];
//    XCTAssertTrue(exists, @"");
//
//    exists = [ftp directoryExistsAtPath:@"/badpath"];
//    XCTAssertFalse(exists, @"");
//
//    bytes = [ftp fileSizeAtPath:@"/badpath.txt"];
//    XCTAssertEqual(-1, bytes, @"");
//
//    // chmod 'test' to 777
//    success = [ftp chmodPath:@"/test" toMode:777];
//    XCTAssertTrue(success, @"");
//
//    // List contents of 'test'
//    contents = [ftp listContentsAtPath:@"/test" showHiddenFiles:YES];
//
//    // - Make sure there are no contents.
//    XCTAssertEqual(0, contents.count, @"There should be no contents");
//
//    // Move 'copy.tgz' to 'test' directory
//    success = [ftp renamePath:@"/copy.tgz" to:@"/test/copy.tgz"];
//    XCTAssertTrue(success, @"");
//
//    // Copy 'copy.tgz' to 'copy2.tgz'
//    success = [ftp copyPath:@"/test/copy.tgz" to:@"/test/copy2.tgz"];
//    XCTAssertTrue(success, @"");
//
//    // Create '/test/test2' directory
//    success = [ftp createDirectoryAtPath:@"/test/test2"];
//    XCTAssertTrue(success, @"");
//
//    NSString *cwd = [ftp printWorkingDirectory];
//    XCTAssertTrue([cwd isEqualToString:@"/"], @"");
//
//    // Change directory to /test
//    success = [ftp changeDirectoryToPath:@"/test"];
//    XCTAssertTrue(success, @"");
//
//    /**
//     Currently the connection is not left open between calls and therefore we
//     will always be put back to the root directory when each command is sent.
//
//     Uncomment this when the same connection is used between commands.
//
//    // Make sure we are still in /test.
//    cwd = [ftp printWorkingDirectory];
//    NSLog(@"cwd is %@", cwd);
//    XCTAssertTrue([cwd isEqualToString:@"/test"], @"");
//     */
//
//    // List contents of 'test'
//    contents = [ftp listContentsAtPath:@"/test" showHiddenFiles:YES];
//
//    // - Should have 'copy.tgz' (a file) and 'test2' (a directory)
//    // @todo make sure they are the files we requested, including the correct
//    // file type.
//    XCTAssertEqual(3, contents.count, @"");
//
//    // Delete 'test'. It should fail as there are contents in the directory.
//    success = [ftp deleteDirectoryAtPath:@"/test"];
//    XCTAssertFalse(success, @"Directory has contents");
//
//    // Delete 'test2', 'copy.tgz' and then 'test'. All operations should succeed.
//    success = [ftp deleteFileAtPath:@"/test/copy.tgz"];
//    XCTAssertTrue(success, @"");
//    success = [ftp deleteFileAtPath:@"/test/copy2.tgz"];
//    XCTAssertTrue(success, @"");
//    success = [ftp deleteDirectoryAtPath:@"/test/test2"];
//    XCTAssertTrue(success, @"");
//    success = [ftp deleteDirectoryAtPath:@"/test"];
//    XCTAssertTrue(success, @"");
    
    //XCTFail(@"No implementation for \"%s\"", __PRETTY_FUNCTION__);
}

@end
