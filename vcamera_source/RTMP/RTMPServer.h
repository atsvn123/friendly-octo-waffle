// RTMPServer.h
// Reconstructed from -[RTMPServer *] methods (0x12B0F8).
// ObjC wrapper around C++ librtmp + libvcam TCPServer.

#import <Foundation/Foundation.h>

@protocol RTMPServerDelegate <NSObject>
- (void)outputFrame:(void *)frameData
  presentationTimeStamp:(int64_t)pts
  presentationDuration:(int64_t)duration;
@end

@interface RTMPServer : NSObject

@property (nonatomic, assign) id<RTMPServerDelegate> delegate;
@property (nonatomic, strong) id h264Decoder;        // H264Decoder instance
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) NSThread *RTMPThread;
@property (nonatomic, assign) BOOL userWantsRunning;  // YES while server should live; only NO on full shutdown
@property (nonatomic, assign) BOOL deliversFrames;    // YES when LIVE is on; NO when LIVE is off but server stays up

// Start RTMP server — idempotent: only spawns thread/TCPServer if not already alive.
// On subsequent calls (LIVE toggle on) just enables frame delivery + reinits decoder.
- (void)startServerLoop;

// Pause frame delivery without touching TCPServer or thread.
// OBS connection stays live. Call on code 1001 (user presses Stop).
- (void)stopDecoding;

// Full shutdown — kills thread, destroys TCPServer. Only for process cleanup or unrecoverable errors.
- (void)stopServer;

// Main accept + decode loop — runs on RTMPThread, calls +runRTMPLoop:
- (void)handleRTMP;

// H264Decoder delegate callback — forward to RTMPServerDelegate (VCamLiveManager)
- (void)outputFrame:(void *)frameData
  presentationTimeStamp:(int64_t)pts
  presentationDuration:(int64_t)duration;

@end

// ─── ObjC++ category — defined in RTMPServerCXX.mm ───────────────────────────
// IDA-confirmed architecture (0xA2998 / 0xA2BB8 / 0xA2B08):
//   startServerLoop:    creates TCPServer (qword_130390), THEN setIsRunning:YES, THEN handleRTMP thread
//   handleRTMP:         accept() on qword_130390, RTMPEndpoint/Session loop
//   stopServer:         destroy + delete + null qword_130390
@interface RTMPServer (CXXLoop)
// Create the TCPServer and bind port 1935. Stores in g_tcpServer (global).
// Called from startServerLoop BEFORE setIsRunning:YES. Returns NO on bind failure.
+ (BOOL)createActiveTCPServer;
// Returns the error string from the last failed createActiveTCPServer, or nil.
+ (NSString *)lastBindError;
// Accept loop — uses already-bound g_tcpServer. Called from handleRTMP.
+ (void)runRTMPAcceptLoop:(RTMPServer *)server;
// Destroy + delete + null g_tcpServer (unblocks accept and frees memory).
+ (void)destroyActiveTCPServer;
@end

#define RTMP_PORT 1935
