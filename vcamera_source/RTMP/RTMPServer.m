// RTMPServer.m
// Reconstructed from -[RTMPServer *] methods (0xA28E0 / 0xA2998 / 0xA2B08 / 0xA2BB8).
// IDA-confirmed architecture:
//   startServerLoop (0xA2998): create H264Decoder → createActiveTCPServer → setIsRunning:YES → start handleRTMP thread
//   stopServer (0xA2B08):      setIsRunning:NO → sleep(1) → cancel RTMPThread → destroyActiveTCPServer → endDecode
//   handleRTMP (0xA2BB8):      if isRunning → accept loop using g_tcpServer → [NSThread exit]

#import "RTMPServer.h"
#import "../H264Decoder/H264Decoder.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../VCamBridge/VCamBridge.h"

// ─── RTMPServer implementation ────────────────────────────────────────────────

@implementation RTMPServer

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

    // Create and start the RTMPThread running handleRTMP
    NSThread *t = [[NSThread alloc] initWithTarget:self
                                          selector:@selector(handleRTMP)
                                            object:nil];
    self.RTMPThread = t;
    [t start];
    [t release];
}

// --- -stopServer (0xA2B08) ---
// IDA-confirmed order: setIsRunning:NO → sleep(1) → cancel RTMPThread → nil RTMPThread
//   → destroyActiveTCPServer (destroy + delete + null qword_130390) → endDecode
- (void)stopServer {
    // Only log when stopping an actively-running server — helps detect unexpected stops.
    if (self.isRunning) {
        vcamSendDiag(@"!stopSrv:active");
        NSLog(@"[VCAM] stopServer called while isRunning=YES");
    }
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
// IDA: checks isRunning, runs accept loop using qword_130390, calls [NSThread exit]
- (void)handleRTMP {
    if (!self.isRunning) {
        [NSThread exit];
        return;
    }
    [RTMPServer runRTMPAcceptLoop:self];
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

@end
