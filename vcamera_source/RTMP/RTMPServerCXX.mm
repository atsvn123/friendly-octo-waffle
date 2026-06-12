// RTMPServerCXX.mm
// Objective-C++ bridge implementing the C++ RTMP accept loop.
// Compiled as ObjC++ (.mm) so it can use librtmp and libvcam C++ classes.
//
// IDA-confirmed architecture (0xA2998 / 0xA2BB8 / 0xA2B08):
//   qword_130390 (= g_tcpServer): global TCPServer*, created in startServerLoop,
//   destroyed + deleted + nulled in stopServer. handleRTMP calls accept on it.

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

// vcamSendDiag is defined in VCamBridge.m — C linkage prevents C++ name mangling.
extern "C" void vcamSendDiag(NSString *msg);

// Send a formatted diagnostic string from the RTMP thread to SpringBoard's menu.
// Uses an @autoreleasepool so NSString formatting works on a thread without a pool.
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

// Mirrors original binary's qword_130390.
static TCPServer *g_tcpServer = nullptr;
static NSString *s_lastBindErr = nil;

@implementation RTMPServer (CXXLoop)

+ (NSString *)lastBindError { return s_lastBindErr; }

// +createActiveTCPServer — called from startServerLoop, BEFORE setIsRunning:YES.
// IDA 0xA2A14: if (!qword_130390) { new TCPServer(0x78F); qword_130390 = v6; }
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

// +destroyActiveTCPServer — called from stopServer.
// IDA 0xA2B5C: destroy + ~TCPServer + delete + qword_130390=0
+ (void)destroyActiveTCPServer {
    if (g_tcpServer) {
        g_tcpServer->destroy();  // close listen socket, unblocks accept()
        delete g_tcpServer;      // calls ~TCPServer + frees memory
        g_tcpServer = nullptr;
    }
}

// +runRTMPAcceptLoop: — called from handleRTMP. Uses the already-bound g_tcpServer.
// IDA 0xA2BB8: do { accept on qword_130390; RTMPEndpoint; RTMPServerSession; GetRTMPMessage loop } while (isRunning)
+ (void)runRTMPAcceptLoop:(RTMPServer *)server {
    while (server.isRunning) {
        if (!g_tcpServer) break;

        int clientFd = -1;
        try {
            clientFd = g_tcpServer->accept();
        } catch (...) {
            if (!server.isRunning) break;
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

            session  = new RTMPServerSession(endpoint);
            rtmpLog("r2:session");

            H264Decoder *decoder = (H264Decoder *)server.h264Decoder;
            int msgCount = 0;

            while (server.isRunning) {
                H264Frame frame = session->GetRTMPMessage();
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
                    // Compute display PTS = DTS + CTS for the software reorder buffer.
                    // compositionTime is a 24-bit signed value stored in uint32 (top 8 bits = 0).
                    // Sign-extend: shift left 8 to move sign bit to bit 31, then arithmetic right.
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
            rtmpLog("r:loop-exit isRunning=%d", (int)server.isRunning);
        } catch (const std::exception &e) {
            rtmpLog("r:ERR %s", e.what());
        } catch (...) {
            rtmpLog("r:disc");  // normal client disconnect (read EOF/ECONNRESET)
        }

        delete session;
        delete endpoint;
        delete layer;   // closes clientFd via DataLayer destructor
    }
    rtmpLog("r:done");
}

@end
