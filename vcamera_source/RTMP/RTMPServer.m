// RTMPServer.m
// Reconstructed from -[RTMPServer *] methods (0xA28E0 / 0xA2998 / 0xA2B08 / 0xA2BB8).
// IDA-confirmed architecture:
//   startServerLoop (0xA2998): create H264Decoder → createActiveTCPServer → setIsRunning:YES → start handleRTMP thread
//   stopServer (0xA2B08):      setIsRunning:NO → sleep(1) → cancel RTMPThread → destroyActiveTCPServer → endDecode
//   handleRTMP (0xA2BB8):      if isRunning → accept loop using g_tcpServer → [NSThread exit]
//
// v2.108 — "unable to kill" hardening:
//   handleRTMP loops on userWantsRunning (not isRunning). External code setting isRunning=NO
//   causes runRTMPAcceptLoop to exit its inner while, but handleRTMP immediately restores
//   isRunning=YES and retries — no shutdown, no sleep. Zero gap.
//   pthread cancellation is disabled inside the thread — external pthread_cancel is ignored.
//   Watchdog GCD timer revives the thread if it is externally killed by process-level signal.
//   stopServer: sets userWantsRunning=NO + isRunning=NO + destroys TCPServer (unblocks accept),
//   then sleeps 1s for clean thread exit before final cleanup.

#import "RTMPServer.h"
#import "../H264Decoder/H264Decoder.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../VCamBridge/VCamBridge.h"
#import <dispatch/dispatch.h>
#import <pthread.h>

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
    RTMPServer *srv = self;
    dispatch_source_set_event_handler(_watchdog, ^{
        if (!srv.userWantsRunning) return;
        NSThread *th = srv.RTMPThread;
        if (!th || th.isFinished || th.isCancelled) {
            // Thread was externally killed — revive it.
            if ([RTMPServer createActiveTCPServer]) {
                [srv _spawnHandleRTMPThread];
            }
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
- (void)startServerLoop {
    if (!self.h264Decoder) {
        H264Decoder *decoder = [[H264Decoder alloc] init];
        decoder.delegate = (id<H264DecoderDelegate>)self;
        self.h264Decoder = decoder;
        [decoder release];
    }

    if (![RTMPServer createActiveTCPServer]) {
        return;
    }

    self.isRunning       = YES;
    self.userWantsRunning = YES;

    [self _spawnHandleRTMPThread];
    [self _startWatchdog];
}

// --- -stopServer (0xA2B08) — only called when user explicitly presses Stop ---
- (void)stopServer {
    if (self.isRunning) {
        vcamSendDiag(@"!stopSrv:active");
        NSLog(@"[VCAM] stopServer called while isRunning=YES");
    }

    // Signal intent BEFORE anything else so handleRTMP loop exits naturally.
    self.userWantsRunning = NO;
    self.isRunning        = NO;

    [self _stopWatchdog];

    // Destroy server socket — unblocks accept() in runRTMPAcceptLoop.
    [RTMPServer destroyActiveTCPServer];

    // Give handleRTMP one second to exit cleanly before we pull the thread.
    sleep(1);
    [self.RTMPThread cancel];
    self.RTMPThread = nil;

    H264Decoder *dec = (H264Decoder *)self.h264Decoder;
    if (dec) [dec endDecode];
    self.h264Decoder = nil;
}

// --- -handleRTMP — loops on userWantsRunning, immune to external isRunning=NO ---
- (void)handleRTMP {
    // Prevent external pthread_cancel from killing this thread.
    // Only userWantsRunning=NO (set by stopServer) terminates the loop.
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);

    while (self.userWantsRunning) {
        // Restore isRunning in case it was flipped externally.
        self.isRunning = YES;

        // createActiveTCPServer: no-op if g_tcpServer is still alive.
        // If it was destroyed, SO_REUSEADDR+SO_REUSEPORT allow instant rebind.
        if (![RTMPServer createActiveTCPServer]) {
            usleep(50000);  // 50ms — port briefly busy, retry
            continue;
        }

        // Blocking accept + session loop. Exits when isRunning=NO or g_tcpServer=null.
        @try {
            [RTMPServer runRTMPAcceptLoop:self];
        } @catch (NSException *ex) {
            NSLog(@"[VCAM] handleRTMP ObjC ex: %@", ex);
        }

        if (!self.userWantsRunning) break;

        // runRTMPAcceptLoop exited while user still wants RTMP.
        // Do NOT destroy the server — if g_tcpServer is still valid, the next
        // createActiveTCPServer call (top of loop) is a no-op and we retry instantly.
        // If g_tcpServer was already destroyed, createActiveTCPServer will rebuild it.
        // Either way: no sleep, no manual destroy — fastest possible recovery.
    }

    self.isRunning = NO;
    [NSThread exit];
}

// --- -outputFrame:presentationTimeStamp:presentationDuration: (0xA28E0) ---
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
