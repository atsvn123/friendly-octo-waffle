// VCamBridge.h
// Reconstructed from iHwCjdhryRasdLfdeOsdPsa (0x12AC20)
// Central IPC singleton bridging SpringBoard ↔ mediaserverd via port 22222

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "../Network/VCamClientSocket.h"
#import "../Network/ServerSocket.h"
#import "../RTMP/RTMPServer.h"

@interface VCamBridge : NSObject <VCamClientSocketDelegate, RTMPServerDelegate>

// Sockets (both created in init; only one used per process)
@property (nonatomic, strong) ServerSocket     *serverSocket;    // mediaserverd side
@property (nonatomic, strong) VCamClientSocket *clientSocket;    // SpringBoard side

// Per-connection accumulation buffers: NSNumber(fd) → NSMutableData
@property (nonatomic, strong) NSMutableDictionary *mapTable;

// RTMP server (mediaserverd side)
@property (nonatomic, strong) RTMPServer   *server;
@property (nonatomic, strong) NSThread     *serverThread;

// SpringBoard back-pointer (weak, assigned by hook)
@property (nonatomic, assign) id springBoard;

// Presented menu VC
@property (nonatomic, strong) UIViewController *menuViewController;

// Session thread (unused in current flow but kept for compat)
@property (nonatomic, strong) NSThread *thread;

// State
@property (nonatomic, assign) BOOL   isPresent;
@property (nonatomic, assign) BOOL   isLogin;
@property (nonatomic, assign) double seconds;   // login timestamp

// Saved credentials
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;

// RTMP frame timestamp (monotonically incremented by 20.0 per decoded frame)
@property (nonatomic, assign) double beginTimeYUV;

+ (instancetype)sharedInstance;

// ── Media server side ──────────────────────────────────────────────────────────
// Start ServerSocket, run CFRunLoop (blocks until socket dies)
- (void)listen;

// Dispatch incoming IPC buffer to the correct handler
- (void)parse:(NSMutableData *)buffer socketHandle:(int)socketHandle;

// Remove accumulation buffer + close socket for a disconnected fd
- (void)remove:(int)socketHandle;

// Login network request → send 1015/1012 back to SpringBoard
- (void)login:(NSString *)username password:(NSString *)password;
- (void)check:(NSString *)username password:(NSString *)password;

// Stop RTMP server
- (void)stop;

// ── SpringBoard side ───────────────────────────────────────────────────────────
// Connect client socket to mediaserverd (127.0.0.1:22222)
- (void)connect;

// Returns YES while client socket is connected
- (BOOL)isConnected;

// VCamClientSocketDelegate — receives data from mediaserverd
- (void)readCallback:(NSData *)data;
- (void)connectCallback;   // no-op in original (0x8A674 = 4 bytes / ret only)

// Send raw data to mediaserverd (via clientSocket)
- (void)send:(NSData *)data;

// Menu lifecycle
- (void)presentation;   // show menu or login dialog
- (void)sigin;          // show UIAlertController login dialog
- (void)dismiss;        // dismiss menu VC

// ── Shared helpers ──────────────────────────────────────────────────────────────
+ (UIWindow *)getKeyWindow;
+ (UIViewController *)getRootViewController;

- (void)startThread;
- (void)run;

- (void)setSpringBoard:(id)sb;
- (void)setResolution:(unsigned int)width height:(unsigned int)height;

// RTMPServerDelegate — receives decoded frames from RTMPServer
- (void)outputFrame:(void *)frameData
 presentationTimeStamp:(int64_t)pts
  presentationDuration:(int64_t)duration;

// Wraps a CVImageBuffer in a CMSampleBuffer with a synthetic timestamp
- (CMSampleBufferRef)imageBufferToSampleBuffer:(CVImageBufferRef)imageBuffer
                                     timeStamp:(double)ts;

- (void)outputVideo:(void *)data sps_size:(int)spsSize pps:(void *)pps pps_size:(int)ppsSize;
- (void)outputVideo:(void *)data size:(int)size;
- (void)endOfOutput;

@end

// Global flags shared across vcamera.dylib translation units
extern volatile uint8_t g_done;             // byte_130150
extern volatile uint8_t g_menuReady;        // byte_130151
extern volatile uint8_t g_lockScreenVisible; // byte_130152 — set by SBLockScreenManager hooks
extern double g_lastResolutionUpdate;
// Last N diagnostic lines joined with \n — SpringBoard side only; set by readCallback:
extern NSString *g_vcamDiag;

// Send a diagnostic string from mediaserverd to SpringBoard via the IPC connection.
// Safe to call from ANY thread in mediaserverd. No-op in SpringBoard.
// C linkage so RTMPServerCXX.mm (ObjC++) can call it without name mangling.
#ifdef __cplusplus
extern "C"
#endif
void vcamSendDiag(NSString *msg);
