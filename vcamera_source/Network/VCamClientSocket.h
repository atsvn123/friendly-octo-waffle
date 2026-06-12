// VCamClientSocket.h
// Reconstructed from iCsdweKdsfRwdaCbv (0x12AB80)
// Client socket: SpringBoard → mediaserverd on 127.0.0.1:22222
// Uses CFSocket (kCFSocketReadCallBack|kCFSocketConnectCallBack) + NSThread.
// Self-heals: reconnects automatically on disconnect, restarts mediaserverd via
// launch_msg("StopJob") every 10 consecutive failures (every 5 s).

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

@protocol VCamClientSocketDelegate <NSObject>
- (void)readCallback:(NSData *)data;
- (void)connectCallback;
@end

@interface VCamClientSocket : NSObject

@property (nonatomic, assign) id<VCamClientSocketDelegate> delegate;
@property (nonatomic, assign) BOOL isConnected;

// Stores host/port, starts the internal NSThread (same thread runs retry loop,
// CFRunLoopRun, reconnect on drop). Mirrors -[iCsdweKdsfRwdaCbv create:port:] 0x86D14.
- (BOOL)create:(NSString *)host port:(uint16_t)port;

// Enqueue bytes for sending. Mirrors -[iCsdweKdsfRwdaCbv write:] 0x86FF8.
- (ssize_t)write:(NSData *)data;

// Tear down current connection and cancel thread. Called by reconnect and dealloc.
- (void)close;

// Called from socketCallBack on disconnect: close + new NSThread.
- (BOOL)reconnect;

// NSThread entry point — retry loop, launch_stop, CFRunLoopRun.
- (void)run;

// Create new CFSocket and non-blocking CFSocketConnectToAddress.
// Returns YES on success (connect initiated), NO on immediate failure.
- (BOOL)connect;

@end
