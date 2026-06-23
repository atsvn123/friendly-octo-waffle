// ServerSocket.h
// Reconstructed from ServerSocket (0x12ABD0)
// Used by VCamBridge::listen — creates TCP server on port 22222

#import <Foundation/Foundation.h>

// Raw-bytes callback: delivers each chunk of received data with its socket fd
typedef void (^ServerSocketDataBlock)(int socketHandle, NSData *data);

@interface ServerSocket : NSObject

// The CFRunLoop running inside the server's dedicated NSThread (set in -run).
// NULL until the thread has started. Use with CFRunLoopPerformBlock to schedule
// work that must run on the ServerSocket thread (e.g. sendAll: calls from other threads).
- (CFRunLoopRef)cfRunLoop;

// Create server socket on given port, invoke callback for each data chunk received.
// Returns YES on success. Starts own NSThread; -run is the thread's entry point.
- (BOOL)create:(uint16_t)port callback:(ServerSocketDataBlock)callback;

// NSThread entry point — adds CFSocket source to run loop and calls CFRunLoopRun.
- (void)run;

// Send data to all currently connected clients (server→client broadcast).
// Direct CFWriteStreamWrite — no queue.
- (void)sendAll:(NSData *)data;

// Write data to a specific connection by fd.
- (void)write:(int)socketHandle data:(NSData *)data;

// Forcibly close a connection by fd.
- (void)close:(int)socketHandle;

@end
