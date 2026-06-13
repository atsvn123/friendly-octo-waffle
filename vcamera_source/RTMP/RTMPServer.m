// RTMPServer.m
// Reconstructed from -[RTMPServer *] methods (0xA28E0 / 0xA2998 / 0xA2B08 / 0xA2BB8).
// IDA-confirmed architecture:
//   startServerLoop (0xA2998): create H264Decoder → createActiveTCPServer → setIsRunning:YES → start handleRTMP thread
//   stopServer (0xA2B08):      setIsRunning:NO → sleep(1) → cancel RTMPThread → destroyActiveTCPServer → endDecode
//   handleRTMP (0xA2BB8):      if isRunning → accept loop using g_tcpServer → [NSThread exit]
//
// v2.107 additions:
//   handleRTMP now loops: after runRTMPAcceptLoop exits (client disconnect / error), if isRunning
//   is still YES (= user hasn't pressed Stop), destroys and recreates TCPServer and retries.
//   A GCD watchdog timer fires every 5s: if isRunning=YES but RTMPThread.isFinished (external
//   kill), it spawns a fresh handleRTMP thread.

#import "RTMPServer.h"
#import "../H264Decoder/H264Decoder.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../VCamBridge/VCamBridge.h"
#import <dispatch/dispatch.h>

// ─── RTMPServer implementation ────────────────────────────────────────────────

@implementation RTMPServer {
    dispatch_source_t _watchdog;
}

// ── helpers ───────────────────────────────────────────────────────────────────

- (void)_spawnHandleRTMPThread {
    NSThread *t = [[NSThread alloc] initWithTarget:self
                                          selector:@selector(handleRTMP)
                                            object:nil];
    self.RTMPThread = t;
    [t start];
    [t release];
}

- (void)_startWatchdog {
    if (_watchdog) return;
    _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    dispatch_source_set_timer(_watchdog,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC,
                              NSEC_PER_SEC);
    RTMPServer *srv = self;  // block retains; broken when source is cancelled
    dispatch_source_set_event_handler(_watchdog, ^{
        if (!srv.isRunning) return;
        NSThread *th = srv.RTMPThread;
        if (!th || th.isFinished || th.isCancelled) {
            // Thread died while user still wants RTMP — revive it
            if (![RTMPServer createActiveTCPServer]) {
                return;  // port busy or other error; try again next tick
            }
            [srv _spawnHandleRTMPThread];
        }
    });
    dispatch_resume(_watchdog);
}

- (void)_stopWatchdog {
    if (_watchdog) {
        dispatch_source_cancel(_watchdog);
        dispatch_release(_watchdog);
        _watchdog = nil;
    }
}

// --- -startServerLoop (0xA2998) ---
// IDA order: H264Decoder → TCPServer (qword_130390) → setIsRunning:YES → start handleRTMP thread
- (void)startServerLoop {
    // Lazy-create H264Decoder (IDA 0xA2998: only alloc if not already present)
    if (!self.h264Decoder) {
        H264Decoder *decoder = [[H264Decoder alloc] init];
        decoder.delegate = (id<H264DecoderDelegate>)self;
        self.h264Decoder = decoder;
        [decoder release];
    }

    // g_tcpServer already bound by parse: code 1000 before this GCD block was dispatched;
    // createActiveTCPServer returns YES immediately (no-op bind).
    if (![RTMPServer createActiveTCPServer]) {
        return;
    }

    // IDA 0xA2A38: setIsRunning:YES called after TCPServer is bound
    self.isRunning = YES;
    self.userWantsRunning = YES;

    [self _spawnHandleRTMPThread];
    [self _startWatchdog];
}

// --- -stopServer (0xA2B08) ---
// IDA-confirmed order: setIsRunning:NO → sleep(1) → cancel RTMPThread → nil RTMPThread
//   → destroyActiveTCPServer (destroy + delete + null qword_130390) → endDecode
- (void)stopServer {
    self.userWantsRunning = NO;

    if (self.isRunning) {
        vcamSendDiag(@"!stopSrv:active");
        NSLog(@"[VCAM] stopServer called while isRunning=YES");
    }

    [self _stopWatchdog];

    self.isRunning = NO;
    sleep(1);
    [self.RTMPThread cancel];
    self.RTMPThread = nil;
    // destroy + delete + null g_tcpServer — unblocks accept() in handleRTMP
    [RTMPServer destroyActiveTCPServer];
    H264Decoder *dec = (H264Decoder *)self.h264Decoder;
    if (dec) [dec endDecode];
    self.h264Decoder = nil;
}

// --- -handleRTMP (0xA2BB8) ---
// Extended: loops while isRunning so a client disconnect or socket error immediately
// reopens the accept socket rather than killing the RTMP server permanently.
- (void)handleRTMP {
    if (!self.isRunning) {
        [NSThread exit];
        return;
    }

    while (self.isRunning) {
        [RTMPServer runRTMPAcceptLoop:self];

        if (!self.isRunning) break;

        // Accept loop returned unexpectedly (client dropped, socket error, etc.)
        // Rebuild the TCP server and try again.
        [RTMPServer destroyActiveTCPServer];
        sleep(1);

        if (!self.isRunning) break;

        if (![RTMPServer createActiveTCPServer]) {
            // Port rebind failed; wait a bit longer before next attempt
            sleep(2);
        }
    }

    [NSThread exit];
}

// --- -outputFrame:presentationTimeStamp:presentationDuration: (0xA28E0) ---
// Called by H264Decoder when a frame is decoded. Forwards to delegate (VCamBridge).
- (void)outputFrame:(void *)frameData
 presentationTimeStamp:(int64_t)pts
  presentationDuration:(int64_t)duration
{
    id<RTMPServerDelegate> del = self.delegate;
    if (del) {
        [del outputFrame:frameData
     presentationTimeStamp:pts
      presentationDuration:duration];
    }
}

- (void)dealloc {
    [self _stopWatchdog];
    [super dealloc];
}

@end
