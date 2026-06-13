// RTMPServer.m
// Reconstructed from -[RTMPServer *] methods (0xA28E0 / 0xA2998 / 0xA2B08 / 0xA2BB8).
//
// v2.110 persistent-server architecture:
//   TCPServer (port 1935) and handleRTMP thread live for the lifetime of the mediaserverd
//   process. Only stopServer() (called on process exit / unrecoverable error) destroys them.
//
//   startServerLoop:  idempotent — reinits H264Decoder, enables deliversFrames, spawns
//                     thread+TCPServer only on first call (or after crash recovery).
//   stopDecoding:     disables frame delivery + endDecodes, but NEVER touches TCPServer or thread.
//                     OBS stays connected across LIVE toggle off/on.
//   stopServer:       full teardown for process cleanup. Sets userWantsRunning=NO so
//                     handleRTMP and runRTMPAcceptLoop both exit cleanly.

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

// ── -startServerLoop — idempotent (0xA2998) ──────────────────────────────────
- (void)startServerLoop {
    // H264Decoder: create if nil, otherwise reinit from saved SPS/PPS for
    // immediate decode after LIVE toggle on (OBS already connected, won't resend SPS/PPS).
    if (!self.h264Decoder) {
        H264Decoder *decoder = [[H264Decoder alloc] init];
        decoder.delegate = (id<H264DecoderDelegate>)self;
        self.h264Decoder = decoder;
        [decoder release];
    } else {
        H264Decoder *dec = (H264Decoder *)self.h264Decoder;
        [dec reinitFromSaved];  // fast resume — no need to wait for OBS to resend SPS/PPS
    }

    // Enable frame delivery BEFORE anything else so no race on deliversFrames.
    self.deliversFrames = YES;

    // TCPServer: createActiveTCPServer is a no-op if g_tcpServer is still alive.
    if (![RTMPServer createActiveTCPServer]) {
        return;
    }

    // Thread: only spawn if not already running.
    NSThread *existing = self.RTMPThread;
    if (existing && !existing.isFinished && !existing.isCancelled) {
        // Thread is alive — just ensure flags are set.
        self.isRunning       = YES;
        self.userWantsRunning = YES;
        return;
    }

    self.isRunning       = YES;
    self.userWantsRunning = YES;

    [self _spawnHandleRTMPThread];
    [self _startWatchdog];
}

// ── -stopDecoding — pause delivery, keep server/thread alive ─────────────────
- (void)stopDecoding {
    self.deliversFrames = NO;
    // endDecode releases the VT hardware decoder session, freeing it for other apps.
    // The H264Decoder object itself is NOT nilled — startServerLoop will reinitFromSaved.
    H264Decoder *dec = (H264Decoder *)self.h264Decoder;
    if (dec) [dec endDecode];
    // TCPServer, handleRTMP thread, userWantsRunning — all untouched.
    // OBS stays connected.
}

// ── -stopServer (0xA2B08) — full teardown, only for process cleanup ───────────
- (void)stopServer {
    self.userWantsRunning = NO;
    self.isRunning        = NO;
    self.deliversFrames   = NO;

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

// ── -handleRTMP — loops on userWantsRunning ───────────────────────────────────
- (void)handleRTMP {
    // Prevent external pthread_cancel from killing this thread.
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);

    while (self.userWantsRunning) {
        self.isRunning = YES;

        // createActiveTCPServer: no-op if g_tcpServer is still alive.
        if (![RTMPServer createActiveTCPServer]) {
            usleep(50000);  // 50ms — port briefly busy, retry
            continue;
        }

        @try {
            [RTMPServer runRTMPAcceptLoop:self];
        } @catch (NSException *ex) {
            NSLog(@"[VCAM] handleRTMP ObjC ex: %@", ex);
        }

        if (!self.userWantsRunning) break;
        // runRTMPAcceptLoop exited (accept failure or g_tcpServer destroyed).
        // Do NOT destroy the server — createActiveTCPServer at top of loop rebuilds if needed.
    }

    self.isRunning = NO;
    [NSThread exit];
}

// ── -outputFrame: (0xA28E0) — only forward when LIVE is on ───────────────────
- (void)outputFrame:(void *)frameData
 presentationTimeStamp:(int64_t)pts
  presentationDuration:(int64_t)duration
{
    if (!self.deliversFrames) return;  // LIVE toggle is off — OBS stays connected but no injection
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
