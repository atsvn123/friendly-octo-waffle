// VCamClientSocket.m
// Reconstructed from iCsdweKdsfRwdaCbv (0x12AB80)
// All methods backed by IDA decompilation of vcamera.dylib.
//
// Architecture (matches original exactly):
//   create:port:   — stores sockaddr_in, starts NSThread → run
//   run            — retry-connect loop (500ms); launch_stop every 10 fails; CFRunLoopRun
//   connect        — CFSocketCreate(flags=5) + CFSocketConnectToAddress(timeout=0)
//   socketCallBack — type=4: setIsConnected+connectCallback; type=1: recv+readCallback
//   reconnect      — close + new NSThread (called on disconnect / send failure)
//   close          — releases socket/source, CFRunLoopStop, cancels thread
//   write:         — raw send() loop, 10ms sleep between chunks
//   launch_stop    — sends launchd "StopJob" via launch_msg (restart mediaserverd)

#import "VCamClientSocket.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import <objc/runtime.h>

// ── Private launch API (from /usr/lib/libSystem.B.dylib) ─────────────────────
// Used by launch_stop() to send "StopJob" message to launchd.
typedef void *launch_data_t;
typedef unsigned int launch_data_type_t;
#define VCAM_LAUNCH_DATA_DICTIONARY  1
#define VCAM_LAUNCH_DATA_ERRNO       8
extern launch_data_t launch_data_alloc(launch_data_type_t type);
extern int           launch_data_dict_insert(launch_data_t dict, launch_data_t what, const char *key);
extern launch_data_t launch_data_free(launch_data_t data);
extern int           launch_data_get_errno(launch_data_t data);
extern launch_data_type_t launch_data_get_type(launch_data_t data);
extern launch_data_t launch_data_new_string(const char *string);
extern launch_data_t launch_msg(launch_data_t data);

// ── Private ivars ─────────────────────────────────────────────────────────────
@interface VCamClientSocket () {
    CFSocketRef        _socket;
    NSThread          *_thread;
    CFRunLoopRef       _runLoop;
    CFRunLoopSourceRef _source;
    struct sockaddr_in _socketAddr;
}
@end

// ── Forward declaration ───────────────────────────────────────────────────────
static void socketCallBack(CFSocketRef s, CFSocketCallBackType type,
                            CFDataRef address, const void *data, void *info);

// ── launch_stop — mirrors _launch_stop (0x86A64) ─────────────────────────────
static void launch_stop(const char *label) {
    launch_data_t dict = launch_data_alloc(VCAM_LAUNCH_DATA_DICTIONARY);
    if (!dict) return;
    launch_data_t str = launch_data_new_string(label);
    launch_data_dict_insert(dict, str, "StopJob");
    launch_data_t response = launch_msg(dict);
    launch_data_free(dict);
    if (response) {
        if (launch_data_get_type(response) == VCAM_LAUNCH_DATA_ERRNO) {
            int err = launch_data_get_errno(response);
            (void)err;
        }
        launch_data_free(response);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
@implementation VCamClientSocket

// ── -init (0x86B48) ───────────────────────────────────────────────────────────
- (instancetype)init {
    self = [super init];
    if (self) {
        _socket       = NULL;
        _thread       = nil;
        _runLoop      = NULL;
        _source       = NULL;
        _isConnected  = NO;
        _delegate     = nil;
        memset(&_socketAddr, 0, sizeof(_socketAddr));
    }
    return self;
}

- (void)dealloc {
    [self close];
    [super dealloc];
}

// ── -create:port: (0x86D14) ───────────────────────────────────────────────────
// Stores address, creates NSThread → run, starts thread.
- (BOOL)create:(NSString *)host port:(uint16_t)port {
    memset(&_socketAddr, 0, sizeof(_socketAddr));
    _socketAddr.sin_len    = sizeof(_socketAddr);
    _socketAddr.sin_family = AF_INET;
    _socketAddr.sin_port   = htons(port);
    _socketAddr.sin_addr.s_addr = inet_addr([host cStringUsingEncoding:NSUTF8StringEncoding]);

    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    NSThread *old = _thread;
    _thread = t;
    [old release];
    [_thread start];
    return YES;
}

// ── -connect (0x86DA0) ────────────────────────────────────────────────────────
// Creates CFSocket with kCFSocketReadCallBack|kCFSocketConnectCallBack (flags=5).
// Non-blocking connect (timeout=0); returns YES if initiated, NO on immediate fail.
- (BOOL)connect {
    if (_socket) {
        CFRelease(_socket);
        _socket = NULL;
    }

    CFSocketContext ctx;
    ctx.version         = 0;
    ctx.retain          = NULL;
    ctx.release         = NULL;
    ctx.copyDescription = NULL;
    ctx.info            = (void *)self;

    _socket = CFSocketCreate(kCFAllocatorDefault,
                              AF_INET, SOCK_STREAM, IPPROTO_TCP,
                              kCFSocketReadCallBack | kCFSocketConnectCallBack,
                              socketCallBack, &ctx);
    if (!_socket) return NO;

    CFDataRef addrData = CFDataCreate(kCFAllocatorDefault,
                                       (const UInt8 *)&_socketAddr,
                                       sizeof(_socketAddr));
    // timeout=0 → non-blocking: returns kCFSocketSuccess(0) or kCFSocketError(-1)
    CFSocketError err = CFSocketConnectToAddress(_socket, addrData, 0.0);
    CFRelease(addrData);

    if (err != kCFSocketSuccess) {
        CFRelease(_socket);
        _socket = NULL;
        return NO;
    }
    return YES;
}

// ── -run (0x86EB4) — NSThread entry point ────────────────────────────────────
// Retry loop (500ms), launch_stop("com.apple.mediaserverd") every 10 failures,
// then CFRunLoopRun() on success. Exits via CFRunLoopStop (from close/reconnect).
- (void)run {
    int v3 = 1;   // attempt counter
    int v4 = -1;  // trigger counter: !(v4 + 10*(v3/10)) fires at attempts 10,20,30...

    while (![self connect]) {
        NSLog(@"connecting ...");
        if (!(v4 + 10 * (v3 / 10))) {
            launch_stop("com.apple.mediaserverd");
        }
        v3++;
        v4--;
        usleep(500000);  // 500ms
    }

    _runLoop = CFRunLoopGetCurrent();
    CFRunLoopSourceRef src = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);
    _source = src;
    CFRunLoopAddSource(_runLoop, _source, kCFRunLoopDefaultMode);
    CFRunLoopRun();

    [NSThread exit];
}

// ── socketCallBack (0x86BB0) — static C callback ─────────────────────────────
// type=kCFSocketConnectCallBack(4): connected → setIsConnected + connectCallback
// type=kCFSocketReadCallBack(1):    data ready → recv → readCallback; EOF → reconnect
static void socketCallBack(CFSocketRef s, CFSocketCallBackType type,
                            CFDataRef address, const void *data, void *info)
{
    VCamClientSocket *vcself = [(VCamClientSocket *)info retain];

    if (type == kCFSocketConnectCallBack) {           // 4 — connect completed
        [vcself setIsConnected:YES];
        id<VCamClientSocketDelegate> d = [vcself delegate];
        if (d) [d connectCallback];

    } else if (type == kCFSocketReadCallBack) {       // 1 — data available
        uint8_t buf[0x5BC];                           // 1468 bytes, matches original
        bzero(buf, sizeof(buf));
        CFSocketNativeHandle fd = CFSocketGetNative(s);
        ssize_t n = recv(fd, buf, sizeof(buf), 0);

        if (n <= 0) {
            [vcself reconnect];
        } else {
            NSData *recvData = [NSData dataWithBytes:buf length:(NSUInteger)n];
            id<VCamClientSocketDelegate> d = [vcself delegate];
            if (d) [d readCallback:recvData];
        }
    }

    [vcself release];
}

// ── -reconnect (0x86E58) ──────────────────────────────────────────────────────
// Called on disconnect: close current connection, spawn new NSThread to retry.
- (BOOL)reconnect {
    [self close];

    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    NSThread *old = _thread;
    _thread = t;
    [old release];
    [_thread start];
    return YES;
}

// ── -close (0x870C4) ──────────────────────────────────────────────────────────
// Marks disconnected, releases socket+source, stops run loop, cancels thread.
- (void)close {
    self.isConnected = NO;

    if (_socket) {
        CFRelease(_socket);
        _socket = NULL;
    }
    if (_source) {
        CFRelease(_source);
        _source = NULL;
    }
    if (_runLoop) {
        NSLog(@"_runLoop 1");
        CFRunLoopStop(_runLoop);
        _runLoop = NULL;
        NSLog(@"_runLoop 2");
    }
    if (_thread) {
        [_thread cancel];
        NSThread *old = _thread;
        _thread = nil;
        [old release];
    }
}

// ── -write: (0x86FF8) ─────────────────────────────────────────────────────────
// Raw send() loop with 10ms sleep between chunks; reconnects on send failure.
// Returns bytes sent (≥0) or negative error code.
- (ssize_t)write:(NSData *)data {
    if (!self.isConnected) return -101;

    const char *bytes = (const char *)[data bytes];
    size_t remaining  = [data length];
    if (!remaining) return 0;

    ssize_t total = 0;
    ssize_t n;

    while (1) {
        CFSocketNativeHandle fd = CFSocketGetNative(_socket);
        n = send(fd, bytes, remaining, 0);
        if (n <= 0) break;

        total     += n;
        bytes     += n;
        remaining -= (size_t)n;
        usleep(10000);  // 10ms = 0x2710 μs, matches original
        if (!remaining) return total;
    }

    // Send failed — reconnect and return error
    [self reconnect];
    return n;
}

@end
