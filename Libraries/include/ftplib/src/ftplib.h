/***************************************************************************/
/*                                                                         */
/* ftplib.h - header file for callable ftp access routines                 */
/* Copyright (C) 1996-2001, 2013 Thomas Pfau, tfpfau@gmail.com             */
/*        1407 Thomas Ave, North Brunswick, NJ, 08902                      */
/*                                                                         */
/* This library is free software.  You can redistribute it and/or          */
/* modify it under the terms of the Artistic License 2.0.                  */
/*                                                                         */
/* This library is distributed in the hope that it will be useful,         */
/* but WITHOUT ANY WARRANTY; without even the implied warranty of          */
/* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           */
/* Artistic License 2.0 for more details.                                  */
/*                                                                         */
/* See the file LICENSE or                                                 */
/* http://www.perlfoundation.org/artistic_license_2_0                      */
/*                                                                         */
/***************************************************************************/

#if !defined(__FTPLIB_H)
#define __FTPLIB_H

#if defined(__unix__) || defined(VMS) || defined(__APPLE__)
#define GLOBALDEF
#define GLOBALREF extern
#elif defined(_WIN32)
#if defined BUILDING_LIBRARY
#define GLOBALDEF __declspec(dllexport)
#define GLOBALREF __declspec(dllexport)
#else
#define GLOBALREF __declspec(dllimport)
#endif
#endif

#include <limits.h>
#include <inttypes.h>

/* FtpAccess() type codes */
#define FTPLIB_DIR                      1
#define FTPLIB_DIR_VERBOSE              2
#define FTPLIB_FILE_READ                3
#define FTPLIB_FILE_READ_OFFSET         4
#define FTPLIB_FILE_WRITE               9
#define FTPLIB_ABORT                    99

/* FtpAccess() mode codes */
#define FTPLIB_ASCII 'A'
#define FTPLIB_IMAGE 'I'
#define FTPLIB_TEXT FTPLIB_ASCII
#define FTPLIB_BINARY FTPLIB_IMAGE

/* connection modes */
#define FTPLIB_PASSIVE 1
#define FTPLIB_PORT 2

/* connection option names */
#define FTPLIB_CONNMODE 1
#define FTPLIB_CALLBACK 2
#define FTPLIB_IDLETIME 3
#define FTPLIB_CALLBACKARG 4
#define FTPLIB_CALLBACKBYTES 5

/* Buffer Length */
// 디렉토리/데이터 읽기에 사용되는 버퍼 크기
#define FTPLIB_BUFFER_LENGTH 32768
// 일반 버퍼 크기
#define FTPLIB_BUFSIZ 8192
#define RESPONSE_BUFSIZ 1024
#define TMP_BUFSIZ 1024
#define ACCEPT_TIMEOUT 30

#define FTPLIB_CONTROL 0
#define FTPLIB_READ 1
#define FTPLIB_WRITE 2

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__UINT64_MAX)
typedef uint64_t fsz_t;
#else
typedef uint32_t fsz_t;
#endif

typedef struct NetBuf netbuf;
typedef int (*FtpCallback)(netbuf *nControl, fsz_t xfered, void *arg);

typedef struct FtpCallbackOptions {
    FtpCallback cbFunc;         /* function to call */
    void *cbArg;                /* argument to pass to function */
    unsigned int bytesXferred;  /* callback if this number of bytes transferred */
    unsigned int idleTime;      /* callback if this many milliseconds have elapsed */
} FtpCallbackOptions;

struct NetBuf {
    char *cput,*cget;
    int handle;
    int cavail,cleft;
    char *buf;
    int dir;
    netbuf *ctrl;
    netbuf *data;
    int cmode;
    struct timeval idletime;
    FtpCallback idlecb;
    void *idlearg;
    unsigned long int xfered;
    unsigned long int cbbytes;
    unsigned long int xfered1;
    char response[RESPONSE_BUFSIZ];
};

GLOBALREF int ftplib_debug;
GLOBALREF void FtpInit(void);
GLOBALREF char *FtpLastResponse(netbuf *nControl);
GLOBALREF int FtpConnect(const char *host, netbuf **nControl);
GLOBALREF int FtpOptions(int opt, long val, netbuf *nControl);
GLOBALREF int FtpSetCallback(const FtpCallbackOptions *opt, netbuf *nControl);
GLOBALREF int FtpClearCallback(netbuf *nControl);
GLOBALREF int FtpLogin(const char *user, const char *pass, netbuf *nControl);
GLOBALREF int FtpAccess(const char *path, int typ, int mode, long long int offset, netbuf *nControl, netbuf **nData);
GLOBALREF int FtpRead(void *buf, int max, netbuf *nData);
GLOBALREF int FtpWrite(const void *buf, int len, netbuf *nData);
GLOBALREF int FtpClose(netbuf *nData);
GLOBALREF int FtpSite(const char *cmd, netbuf *nControl);
GLOBALREF int FtpSysType(char *buf, int max, netbuf *nControl);
GLOBALREF int FtpSendCmd(const char *cmd, char expresp, netbuf *nControl);
GLOBALREF int FtpMkdir(const char *path, netbuf *nControl);
GLOBALREF int FtpChdir(const char *path, netbuf *nControl);
GLOBALREF int FtpCDUp(netbuf *nControl);
GLOBALREF int FtpRmdir(const char *path, netbuf *nControl);
GLOBALREF int FtpPwd(char *path, int max, netbuf *nControl);
GLOBALREF int FtpNlst(const char *output, const char *path, netbuf *nControl);
GLOBALREF int FtpDir(const char *output, const char *path, netbuf *nControl);
/**
 * FtpDirData
 *
 * LIST command 전송, 결과를 Data 포인터로 쓴다
 *
 * @return 1 if successful, 0 otherwise
 * @param bufferData 결과를 쓸 이중 포인터
 * @param path FTP 경로
 * @param nControl 접속할 FTP 주소/정보가 격납된 netbuf 포인터
 */
GLOBALDEF int FtpDirData(char **bufferData, const char *path, netbuf *nControl);

GLOBALREF int FtpSize(const char *path, unsigned int *size, char mode, netbuf *nControl);
#if defined(__UINT64_MAX)
GLOBALREF int FtpSizeLong(const char *path, fsz_t *size, char mode, netbuf *nControl);
#endif
GLOBALREF int FtpModDate(const char *path, char *dt, int max, netbuf *nControl);
GLOBALREF int FtpGet(const char *output, const char *path, char mode, netbuf *nControl);
/**
 * FtpGetData
 * - Get Command 로 정해진 위치에서 정해진 길이만큼의 데이터를 다운로드 받는 메쏘드
 *
 * @return 성공시 1 반환. 실패시 0 반환
 * @param bufferData 결과를 쓸 이중 포인터
 * @param path FTP 경로
 * @param offset 다운로드 개시 위치
 * @param length 다운로드 길이
 * @param nControl 접속할 FTP 주소/정보가 격납된 netbuf 포인터
 */
GLOBALDEF int FtpGetData(char **bufferData,
                         const char *path,
                         char mode,
                         long long int offset,
                         long long int length,
                         netbuf *nControl);
GLOBALREF int FtpPut(const char *input, const char *path, char mode, netbuf *nControl);
GLOBALREF int FtpRename(const char *src, const char *dst, netbuf *nControl);
GLOBALREF int FtpDelete(const char *fnm, netbuf *nControl);
GLOBALREF void FtpQuit(netbuf *nControl);

#ifdef __cplusplus
};
#endif

#endif /* __FTPLIB_H */
