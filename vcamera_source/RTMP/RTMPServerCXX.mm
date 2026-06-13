// RTMPServerCXX.mm
// Objective-C++ bridge implementing the C++ RTMP accept loop.
// Compiled as ObjC++ (.mm) so it can use librtmp and libvcam C++ classes.

#import "RTMPServer.h"
#import "../H264Decoder/H264Decoder.h"
#import "TCPServer.h"
#import "DataLayer.h"
#import "librtmp/RTMPEndpoint.h"
#import "librtmp/RTMPServerSession.h"
#import "../VCamBridge/VCamBridge.h"
#import <Foundation/Foundation.h>
#import <stdexcept>
#import <string>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

using libvcam::TCPServer;
using libvcam::DataLayer;
using librtmp::RTMPEndpoint;
using librtmp::RTMPServerSession;
using librtmp::H264Frame;

extern "C" void vcamSendDiag(NSString *msg);

static void rtmpLog(const char *format, ...) {
    char buf[128];
    va_list args;
    va_start(args, format);
    vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);
    NSLog(@"[VCAM-RTMP] %s", buf);
    @autoreleasepool {
        vcamSendDiag([NSString stringWithUTF8String:buf]);
    }
}

static TCPServer *g_tcpServer = nullptr;
static NSString *s_lastBindErr = nil;

@implementation RTMPServer (CXXLoop)

+ (NSString *)lastBindError { return s_lastBindErr; }

+ (BOOL)createActiveTCPServer {
    [s_lastBindErr release]; s_lastBindErr = nil;
    if (g_tcpServer) return YES;
    try {
        g_tcpServer = new TCPServer(RTMP_PORT);
        return YES;
    } catch (const std::exception &e) {
        s_lastBindErr = [[NSString alloc] initWithUTF8String:e.what()];
        return NO;
    } catch (...) {
        s_lastBindErr = [@"unknown C++ exception" retain];
        return NO;
    }
}

+ (void)destroyActiveTCPServer {
    if (g_tcpServer) {
        g_tcpServer->destroy();
        delete g_tcpServer;
        g_tcpServer = nullptr;
    }
}

// +runRTMPAcceptLoop: — blocking accept + session loop on g_tcpServer.
//
// v2.110 changes:
//   1. Outer accept loop: uses userWantsRunning (not isRunning) so external isRunning=NO
//      does NOT exit the loop. Only explicit stopServer() (userWantsRunning=NO) stops it.
//   2. Accept failure counter: if accept() fails 5+ consecutive times, g_tcpServer may be
//      dead (socket closed externally without our knowledge). Destroy it and break so
//      handleRTMP outer loop rebuilds via createActiveTCPServer. Prevents busy-loop.
//   3. Session message loop: uses userWantsRunning instead of isRunning for same reason.
//   4. Transient error retry: GetRTMPMessage() can throw EINTR when iOS briefly suspends
//      mediaserverd during AVCaptureSession reconfiguration (e.g. Camera.app opens).
//      Up to 3 retries with 10ms gap before treating as genuine disconnect.
//      This prevents OBS losing connection on transient kernel interrupts.

+ (void)runRTMPAcceptLoop:(RTMPServer *)server {
    int acceptFailCount = 0;

    while (server.userWantsRunning) {  // userWantsRunning: immune to external isRunning=NO
        if (!g_tcpServer) break;

        int clientFd = -1;
        try {
            clientFd = g_tcpServer->accept();
            acceptFailCount = 0;  // reset on success
        } catch (...) {
            if (!server.userWantsRunning) break;
            if (++acceptFailCount > 5) {
                // accept() failing repeatedly — socket may be dead (not just EINTR).
                // Destroy and let handleRTMP outer loop rebuild via createActiveTCPServer.
                rtmpLog("r:accept-dead, rebuilding");
                [RTMPServer destroyActiveTCPServer];
                break;
            }
            usleep(100000);  // 100ms between retries
            continue;
        }

        rtmpLog("r0:accept fd=%d", clientFd);

        DataLayer         *layer    = nullptr;
        RTMPEndpoint      *endpoint = nullptr;
        RTMPServerSession *session  = nullptr;

        try {
            layer    = new DataLayer(clientFd);
            endpoint = new RTMPEndpoint(layer);
            endpoint->doHandshake();
            rtmpLog("r1:handshake");

            session = new RTMPServerSession(endpoint);
            rtmpLog("r2:session");

            H264Decoder *decoder = (H264Decoder *)server.h264Decoder;
            int msgCount = 0;
            int errCount = 0;  // consecutive GetRTMPMessage failures for retry logic

            // Session message loop: userWantsRunning so external isRunning=NO is ignored.
            while (server.userWantsRunning) {
                H264Frame frame;
                try {
                    frame = session->GetRTMPMessage();
                    errCount = 0;  // success — reset retry counter
                } catch (...) {
                    // Transient error: Camera.app photo capture or recording start causes
                    // AVFoundation reconfiguration, which can disrupt recv() for up to ~1s
                    // on dual-camera devices (iPhone 7 Plus) or A11 (iPhone 8).
                    // Budget: 10 × 100ms = 1000ms — survives the worst-case reconfig window.
                    if (++errCount <= 10 && server.userWantsRunning) {
                        usleep(100000);  // 100ms
                        // Refresh decoder ref in case stopDecoding was called during sleep.
                        decoder = (H264Decoder *)server.h264Decoder;
                        continue;
                    }
                    throw;  // 10+ consecutive failures or userWantsRunning=NO → genuine disconnect
                }

                // Refresh decoder ref every message — stopDecoding may have changed it.
                decoder = (H264Decoder *)server.h264Decoder;

                msgCount++;
                if (msgCount <= 5) {
                    rtmpLog("r3:msg%d", msgCount);
                }

                if (frame.isSequenceHeader) {
                    if (!frame.sps.empty() && !frame.pps.empty()) {
                        rtmpLog("r4:sps-pps");
                        [decoder initDecoder:frame.sps.data()
                                     spsSize:frame.sps.size()
                                         pps:frame.pps.data()
                                     ppsSize:frame.pps.size()];
                        rtmpLog("r5:decoder-init");
                    }
                } else if (!frame.nalu.empty()) {
                    int32_t signedCTS = (int32_t)(frame.compositionTime << 8) >> 8;
                    int32_t pts       = (int32_t)frame.timestamp + signedCTS;
                    @try {
                        [decoder decode:frame.nalu.data() size:frame.nalu.size() pts:pts];
                        if (msgCount <= 10) rtmpLog("r6:decode-ok");
                    } @catch (NSException *ex) {
                        rtmpLog("r:ObjCEX %.50s", [[ex reason] UTF8String] ?: "?");
                    }
                }
            }
            rtmpLog("r:loop-exit uWR=%d", (int)server.userWantsRunning);
        } catch (const std::exception &e) {
            rtmpLog("r:ERR %s", e.what());
        } catch (...) {
            rtmpLog("r:disc");
        }

        delete session;
        delete endpoint;
        delete layer;   // closes clientFd via DataLayer destructor
    }
    rtmpLog("r:done");
}

@end
