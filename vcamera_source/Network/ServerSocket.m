// ServerSocket.m
// CFSocket-based TCP server on port 22222 (mediaserverd side of VCamBridge IPC).
// Reconstructed from ServerSocket class at 0x12ABD0.
//
// Architecture (matches original exactly):
//   init             — NSRecursiveLock + NSMutableDictionary
//   create:callback: — CFSocket + INADDR_ANY + SO_REUSEADDR + starts NSThread
//   run              — NSThread entry: CFSocketCreateRunLoopSource + kCFRunLoopDefaultMode + CFRunLoopRun
//   AcceptCallBack_c — open streams FIRST, THEN set client callbacks
//   ReadStreamCB     — flags: HasBytesAvailable|ErrorOccurred (0xA) — NO EndEncountered
//   WriteStreamCB    — flags: CanAcceptBytes|ErrorOccurred (0xC) — only handles ErrorOccurred
//   sendAll:         — direct CFWriteStreamWrite (no queue)
//   write:data:      — direct CFWriteStreamWrite (no queue)

#import "ServerSocket.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

// Per-connection context. calloc(1, sizeof(ConnCtx)), freed in CloseConnection.
typedef struct {
    __unsafe_unretained ServerSocket *server;  // back-pointer (not retained)
    int               socketFd;
    CFReadStreamRef   readStream;
    CFWriteStreamRef  writeStream;
    uint8_t           recvBuf[4096];
    size_t            recvLen;
} ConnCtx;

// Forward declarations
static void AcceptCallBack_c(CFSocketRef, CFSocketCallBackType, CFDataRef, const void *, void *);
static void ReadStreamCB(CFReadStreamRef,  CFStreamEventType, void *);
static void WriteStreamCB(CFWriteStreamRef, CFStreamEventType, void *);
static void CloseConnection(ConnCtx *ctx);
static void ProcessInboundData(ConnCtx *ctx);

// ─── ServerSocket ─────────────────────────────────────────────────────────────

@implementation ServerSocket {
    CFSocketRef        _listenSocket;
    CFRunLoopSourceRef _source;
    NSThread          *_thread;
    NSRecursiveLock   *_lock;
    NSMutableDictionary *_connections;  // NSNumber(fd) → NSValue(ConnCtx*)
    ServerSocketDataBlock _callback;
    CFRunLoopRef       _cfRunLoop;      // run loop of the server's NSThread; set in -run
}

// ── -init (0x871F8) ───────────────────────────────────────────────────────────
- (instancetype)init {
    self = [super init];
    if (self) {
        _lock        = [[NSRecursiveLock alloc] init];
        _connections = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    if (_listenSocket) {
        CFSocketInvalidate(_listenSocket);
        CFRelease(_listenSocket);
        _listenSocket = NULL;
    }
    if (_source) {
        CFRelease(_source);
        _source = NULL;
    }
    [_thread cancel];
    [_thread release];
    _thread = nil;
    [_callback release];
    [_connections release];
    [_lock release];
    [super dealloc];
}

- (NSMutableDictionary *)mapTable { return _connections; }
- (ServerSocketDataBlock)dataCallback { return _callback; }

// ── -create:callback: (0x87780) ───────────────────────────────────────────────
// Creates listening socket on port, stores callback, starts own NSThread.
// Returns YES on success; NSThread's -run handles CFRunLoopRun.
- (BOOL)create:(uint16_t)port callback:(ServerSocketDataBlock)cb {
    [_callback release];
    _callback = [cb copy];

    CFSocketContext ctx = { 0, (__bridge void *)self, NULL, NULL, NULL };
    _listenSocket = CFSocketCreate(kCFAllocatorDefault,
                                    PF_INET, SOCK_STREAM, IPPROTO_TCP,
                                    kCFSocketAcceptCallBack,
                                    AcceptCallBack_c,
                                    &ctx);
    if (!_listenSocket) return NO;

    int yes = 1;
    CFSocketNativeHandle nfd = CFSocketGetNative(_listenSocket);
    setsockopt(nfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = 0;   // INADDR_ANY — matches original (NOT INADDR_LOOPBACK)

    CFDataRef addrData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&addr, sizeof(addr));
    CFSocketError err = CFSocketSetAddress(_listenSocket, addrData);
    CFRelease(addrData);

    if (err != kCFSocketSuccess) {
        CFSocketInvalidate(_listenSocket);
        CFRelease(_listenSocket);
        _listenSocket = NULL;
        return NO;
    }

    // Start dedicated NSThread — its run method drives the CFRunLoop
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    NSThread *old = _thread;
    _thread = t;
    [old release];
    [_thread start];

    return YES;
}

// ── -cfRunLoop ────────────────────────────────────────────────────────────────
- (CFRunLoopRef)cfRunLoop { return _cfRunLoop; }

// ── -run (0x878D0) — NSThread entry point ────────────────────────────────────
// Adds accept source to this thread's run loop, then enters CFRunLoopRun.
- (void)run {
    _cfRunLoop = CFRunLoopGetCurrent();  // store before entering run loop
    _source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _listenSocket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _source, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    _cfRunLoop = NULL;
}

// ── -sendAll: (0x87920) ───────────────────────────────────────────────────────
// Broadcast data to all active connections via direct CFWriteStreamWrite.
- (void)sendAll:(NSData *)data {
    if (!data || !data.length) return;
    NSArray *keys = [_connections allKeys];
    for (NSNumber *key in keys) {
        NSValue *val = _connections[key];
        if (!val) continue;
        ConnCtx *ctx = (ConnCtx *)[val pointerValue];
        if (!ctx || !ctx->writeStream) continue;
        CFWriteStreamWrite(ctx->writeStream,
                           (const UInt8 *)[data bytes],
                           (CFIndex)[data length]);
    }
}

// ── -write:data: (0x87A40) ────────────────────────────────────────────────────
// Write to a specific connection by fd.
- (void)write:(int)socketHandle data:(NSData *)data {
    if (!data || !data.length) return;
    NSNumber *key = @(socketHandle);
    NSValue *val = _connections[key];
    if (!val) return;
    ConnCtx *ctx = (ConnCtx *)[val pointerValue];
    if (!ctx || !ctx->writeStream) return;
    CFWriteStreamWrite(ctx->writeStream,
                       (const UInt8 *)[data bytes],
                       (CFIndex)[data length]);
}

// ── -close: (0x87B28) ─────────────────────────────────────────────────────────
// Close a specific connection by fd (IDA method name: close:, NOT remove:).
- (void)close:(int)socketHandle {
    NSNumber *key = @(socketHandle);
    NSValue *val = _connections[key];
    if (val) {
        ConnCtx *ctx = (ConnCtx *)[val pointerValue];
        if (ctx) CloseConnection(ctx);
    }
}

@end

// ─── AcceptCallBack (0x87578) ─────────────────────────────────────────────────
// Order: open streams FIRST, then set client callbacks, then schedule.
// Read flags  = kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred (0xA)
// Write flags = kCFStreamEventCanAcceptBytes    | kCFStreamEventErrorOccurred (0xC)

static void AcceptCallBack_c(CFSocketRef socket,
                              CFSocketCallBackType type,
                              CFDataRef address,
                              const void *data,
                              void *info)
{
    if (type != kCFSocketAcceptCallBack) return;

    CFSocketNativeHandle nativeFd = *(CFSocketNativeHandle *)data;
    ServerSocket *server = (__bridge ServerSocket *)info;

    ConnCtx *ctx = (ConnCtx *)calloc(1, sizeof(ConnCtx));
    ctx->server   = server;
    ctx->socketFd = (int)nativeFd;
    ctx->recvLen  = 0;

    CFReadStreamRef  readStream  = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeFd, &readStream, &writeStream);

    if (!readStream || !writeStream) {
        close(nativeFd);
        free(ctx);
        if (readStream)  CFRelease(readStream);
        if (writeStream) CFRelease(writeStream);
        return;
    }

    ctx->readStream  = readStream;
    ctx->writeStream = writeStream;

    // Open streams FIRST (matches original 0x87578)
    CFReadStreamOpen(readStream);
    CFWriteStreamOpen(writeStream);

    // Insert into mapTable BEFORE SetClient — prevents race where ReadStreamCB
    // fires (HasBytesAvailable) before the fd is in the map and loses the data.
    NSValue  *ctxVal = [NSValue valueWithPointer:ctx];
    NSNumber *fdKey  = [NSNumber numberWithInt:(int)nativeFd];
    [[server mapTable] setObject:ctxVal forKey:fdKey];

    // Then set client callbacks
    CFStreamClientContext streamCtx = { 0, ctx, NULL, NULL, NULL };
    CFReadStreamSetClient(readStream,
        kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred,   // 0xA, NO EndEncountered
        ReadStreamCB, &streamCtx);
    CFWriteStreamSetClient(writeStream,
        kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred,       // 0xC
        WriteStreamCB, &streamCtx);

    // Schedule on this thread's run loop (kCFRunLoopCommonModes per original)
    CFRunLoopRef rl = CFRunLoopGetCurrent();
    CFReadStreamScheduleWithRunLoop(readStream,   rl, kCFRunLoopCommonModes);
    CFWriteStreamScheduleWithRunLoop(writeStream, rl, kCFRunLoopCommonModes);
}

// ─── ReadStreamCB (0x872B0) ───────────────────────────────────────────────────
// Flags 0xA = HasBytesAvailable | ErrorOccurred. No EndEncountered handling.

static void ReadStreamCB(CFReadStreamRef stream, CFStreamEventType event, void *info) {
    ConnCtx *ctx = (ConnCtx *)info;

    if (event == kCFStreamEventHasBytesAvailable) {
        size_t available = sizeof(ctx->recvBuf) - ctx->recvLen;
        if (!available) {
            // Buffer full — flush existing data first
            ProcessInboundData(ctx);
            available = sizeof(ctx->recvBuf);
        }
        CFIndex n = CFReadStreamRead(stream, ctx->recvBuf + ctx->recvLen, (CFIndex)available);
        if (n > 0) {
            ctx->recvLen += (size_t)n;
            ProcessInboundData(ctx);
        } else if (n < 0) {
            CloseConnection(ctx);
        }
    } else if (event == kCFStreamEventErrorOccurred) {
        CloseConnection(ctx);
    }
    // kCFStreamEventEndEncountered intentionally NOT handled (matches original 0x872B0)
}

// ─── WriteStreamCB (0x87464) ─────────────────────────────────────────────────
// Original only handles kCFStreamEventErrorOccurred (type=8). No queue drain.

static void WriteStreamCB(CFWriteStreamRef stream, CFStreamEventType event, void *info) {
    (void)stream;
    ConnCtx *ctx = (ConnCtx *)info;
    if (event == kCFStreamEventErrorOccurred) {
        CloseConnection(ctx);
    }
    // kCFStreamEventCanAcceptBytes registered but not acted on (matches original)
}

// ─── ProcessInboundData ───────────────────────────────────────────────────────

static void ProcessInboundData(ConnCtx *ctx) {
    if (ctx->recvLen == 0) return;
    ServerSocketDataBlock cb = [ctx->server dataCallback];
    if (!cb) { ctx->recvLen = 0; return; }
    NSData *data = [[NSData alloc] initWithBytes:ctx->recvBuf length:ctx->recvLen];
    cb(ctx->socketFd, data);
    [data release];
    ctx->recvLen = 0;
}

// ─── CloseConnection ─────────────────────────────────────────────────────────
// Notify the callback with nil data (bridge removes connection from its map),
// then unschedule + close streams.

static void CloseConnection(ConnCtx *ctx) {
    // Notify bridge that this fd is gone (data=nil → [bridge remove:fd])
    ServerSocketDataBlock cb = [ctx->server dataCallback];
    if (cb) cb(ctx->socketFd, nil);

    CFRunLoopRef rl = CFRunLoopGetCurrent();

    if (ctx->readStream) {
        CFReadStreamUnscheduleFromRunLoop(ctx->readStream, rl, kCFRunLoopCommonModes);
        CFReadStreamSetClient(ctx->readStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamClose(ctx->readStream);
        CFRelease(ctx->readStream);
        ctx->readStream = NULL;
    }
    if (ctx->writeStream) {
        CFWriteStreamUnscheduleFromRunLoop(ctx->writeStream, rl, kCFRunLoopCommonModes);
        CFWriteStreamSetClient(ctx->writeStream, kCFStreamEventNone, NULL, NULL);
        CFWriteStreamClose(ctx->writeStream);
        CFRelease(ctx->writeStream);
        ctx->writeStream = NULL;
    }
    close(ctx->socketFd);

    NSNumber *fdKey = [NSNumber numberWithInt:ctx->socketFd];
    [[ctx->server mapTable] removeObjectForKey:fdKey];

    free(ctx);
}
