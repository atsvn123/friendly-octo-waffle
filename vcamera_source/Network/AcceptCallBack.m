// AcceptCallBack.m
// Reconstructed from AcceptCallBack (0x87578) and ReadStreamClientCallBack (0x872B0),
// WriteStreamClientCallBack (0x87464)
// Handles accepted socket connections in mediaserverd

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// Structure allocated per connection (calloc(1, 0x3978))
// Layout (inferred from decompilation):
//   offset +0x00: ServerSocket *serverSocket
//   offset +0x08: int socketFd (native socket fd)
//   offset +0x10: CFReadStreamRef readStream
//   offset +0x3978-8: CFWriteStreamRef writeStream
typedef struct {
    id serverSocket;
    int socketFd;
    uint8_t padding[4];
    CFReadStreamRef readStream;
    // ... (0x3978 bytes total)
    // CFWriteStreamRef writeStream at (offset 1838 * sizeof(void*)) = 0x38E0
} ConnectionContext;

// AcceptCallBack (0x87578)
// Called by CFSocket when a new connection arrives (kCFSocketAcceptCallBack = 2)
// Creates CFReadStream + CFWriteStream pair and schedules them on the run loop
void AcceptCallBack(CFSocketRef socket,
                    CFSocketCallBackType type,
                    CFDataRef address,
                    const void *data,
                    void *info)
{
    if (type != kCFSocketAcceptCallBack) return;

    // data contains the native socket fd for the new connection
    CFSocketNativeHandle nativeFd = *(CFSocketNativeHandle *)data;

    // Allocate per-connection context (0x3978 bytes)
    ConnectionContext *ctx = (ConnectionContext *)calloc(1, 0x3978);
    ctx->serverSocket = (id)info;
    ctx->socketFd = nativeFd;

    // Create read+write stream pair from native socket
    CFReadStreamRef  readStream  = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeFd, &readStream, &writeStream);

    if (!readStream || !writeStream || !CFReadStreamOpen(readStream) || !CFWriteStreamOpen(writeStream)) {
        close(nativeFd);
        free(ctx);
        return;
    }

    ctx->readStream = readStream;
    // ctx->writeStream = writeStream; (at high offset)

    // Register with NSValue map (keyed by fd) so the server can track connections
    NSValue *ctxValue = [NSValue valueWithPointer:ctx];
    NSNumber *fdKey   = [NSNumber numberWithInt:nativeFd];
    // serverSocket.mapTable[fdKey] = ctxValue
    id mapTable = [(id)info performSelector:@selector(mapTable)];
    [mapTable setObject:ctxValue forKey:fdKey];

    // Set up read stream callback (ReadStreamClientCallBack at 0x872B0)
    CFStreamClientContext clientCtx = { 0, ctx, NULL, NULL, NULL };
    if (CFReadStreamSetClient(readStream,
                              kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred,
                              NULL, // ReadStreamClientCallBack
                              &clientCtx)) {
        // Set up write stream callback (WriteStreamClientCallBack at 0x87464)
        CFStreamClientContext writeClientCtx = { 0, ctx, NULL, NULL, NULL };
        if (CFWriteStreamSetClient(writeStream,
                                   kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred,
                                   NULL, // WriteStreamClientCallBack
                                   &writeClientCtx)) {
            // Schedule both streams on current run loop
            CFRunLoopRef runLoop = CFRunLoopGetCurrent();
            CFReadStreamScheduleWithRunLoop(readStream,  runLoop, kCFRunLoopCommonModes);
            CFWriteStreamScheduleWithRunLoop(writeStream, runLoop, kCFRunLoopCommonModes);
            return;
        }
    }

    // Failed to set clients — clean up
    CFReadStreamClose(readStream);
    CFWriteStreamClose(writeStream);
    close(nativeFd);
    free(ctx);
}
