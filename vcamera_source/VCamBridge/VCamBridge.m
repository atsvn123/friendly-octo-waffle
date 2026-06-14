// VCamBridge.m
// Reconstructed from iHwCjdhryRasdLfdeOsdPsa (0x12AC20)
// All method implementations backed by IDA decompilation — v2.18
//
// Key confirmed addresses:
//   readCallback:     0x8A7A0  — inline, no _responseBuffer
//   connectCallback   0x8A674  — 4-byte ret (genuine no-op)
//   parse:socketHandle: 0x899E0
//   run               0x88404  — sleep(0x78) + send 1016 loop
//   stop              0x8B3C0  — _beginTimeYUV=0 first
//   login:password:   0x891A0  — uses [iCdfsIdfdEdfsNdfdftqWer sharedInstance]
//   listen            0x8A214
//   remove:           0x89084  — removes from mapTable + closes socket

#import "VCamBridge.h"
#import "../Network/VCamClientSocket.h"
#import "../Network/ServerSocket.h"
#import "../Network/VCamNetworkRequest.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../RTMP/RTMPServer.h"
#import "../UI/VCamMenuViewController.h"
#import <UIKit/UIKit.h>

// Dedicated high-level UIWindow for the menu — stays above all apps.
// Created lazily on first showMainMenu call; hidden (not nil) after dismiss.
static UIWindow *s_menuWindow = nil;
#import <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

// ── Private method declarations ──────────────────────────────────────────────
@interface VCamBridge ()
- (void)showMainMenu;
- (void)saveCredentials;
- (NSDictionary *)loadCredentials;
@end

// ── Globals (binary globals 0x130150, 0x130151) ──────────────────────────────
volatile uint8_t g_done             = 0;  // byte_130150
volatile uint8_t g_menuReady        = 0;  // byte_130151
volatile uint8_t g_lockScreenVisible = 0; // byte_130152
double g_lastResolutionUpdate = 0.0;

// Last N diagnostic lines joined with \n — SpringBoard side only
NSString *g_vcamDiag = nil;

// ── IPC packet helpers ────────────────────────────────────────────────────────

static NSData *makeErrorPacket(int32_t code, NSString *msg) {
    NSMutableData *d = [NSMutableData dataWithCapacity:16];
    [d appendBytes:&code length:4];
    const char *utf8 = msg ? [msg UTF8String] : "";
    int32_t len = (int32_t)strlen(utf8);
    [d appendBytes:&len length:4];
    if (len > 0) [d appendBytes:utf8 length:(NSUInteger)len];
    return [NSData dataWithData:d];
}

// ── vcamSendDiag — cross-process diagnostic (mediaserverd → SpringBoard) ─────
// Schedules a 2001 IPC packet on the ServerSocket's CFRunLoop thread so sendAll:
// is called from the correct thread. Safe from any thread. No-op in SpringBoard
// (listen is never called there, _serverSocket.cfRunLoop stays NULL).
void vcamSendDiag(NSString *msg) {
    if (!msg) return;
    VCamBridge *bridge = [VCamBridge sharedInstance];
    ServerSocket *sock = [bridge serverSocket];
    if (!sock) return;
    CFRunLoopRef rl = [sock cfRunLoop];
    if (!rl) return;

    // Build the packet on the calling thread (no autorelease needed — alloc+init).
    const char *utf8 = [msg UTF8String];
    int32_t msgLen = utf8 ? (int32_t)strlen(utf8) : 0;
    int32_t code = 2001;
    NSMutableData *pkt = [[NSMutableData alloc] initWithCapacity:(NSUInteger)(8 + msgLen)];
    [pkt appendBytes:&code   length:4];
    [pkt appendBytes:&msgLen length:4];
    if (msgLen > 0) [pkt appendBytes:utf8 length:(NSUInteger)msgLen];

    [sock retain];  // block will release
    CFRunLoopPerformBlock(rl, kCFRunLoopDefaultMode, ^{
        [sock sendAll:pkt];
        [pkt release];
        [sock release];
    });
    CFRunLoopWakeUp(rl);
    // usleep(10000) removed: crash that required guaranteed ordering is fixed.
    // Probes are delivered asynchronously; SpringBoard receives them in order.
}

// ── VCamBridge ────────────────────────────────────────────────────────────────

@implementation VCamBridge

// ─── +sharedInstance (0x87E54) ────────────────────────────────────────────────
+ (instancetype)sharedInstance {
    static VCamBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamBridge alloc] init];
    });
    return instance;
}

// ─── -init (0x87EF0) ──────────────────────────────────────────────────────────
// Confirmed: original init does NOT create _responseBuffer
- (instancetype)init {
    self = [super init];
    if (self) {
        self.isPresent = NO;
        self.isLogin   = NO;
        self.seconds   = [[NSDate date] timeIntervalSince1970];

        _serverSocket = [[ServerSocket alloc] init];
        _clientSocket = [[VCamClientSocket alloc] init];
        [_clientSocket setDelegate:self];

        _mapTable = [[NSMutableDictionary alloc] initWithCapacity:1];
    }
    return self;
}

// ─── -listen (0x8A214) — mediaserverd side ────────────────────────────────────
// Original: do { create:22222 callback:block; usleep(10000); } while (!success)
// ServerSocket internally starts its own NSThread running CFRunLoopRun.
- (void)listen {
    BOOL success = NO;
    do {
        __block VCamBridge *blockSelf = self;
        success = [_serverSocket create:22222 callback:^(int fd, NSData *data) {
            @synchronized(blockSelf) {
                if (!data) {
                    // nil data = connection closed — confirmed: sub_8A2A0 calls [self remove:fd]
                    [blockSelf remove:fd];
                    return;
                }
                NSNumber *key = @(fd);
                NSMutableData *buf = blockSelf->_mapTable[key];
                if (!buf) {
                    buf = [NSMutableData dataWithCapacity:256];
                    blockSelf->_mapTable[key] = buf;
                }
                [buf appendData:data];
                [blockSelf parse:buf socketHandle:fd];
            }
        }];
        usleep(10000);   // IDA: unconditional — sleeps even on success
    } while (!success);
}

// ─── -connect (0x8AD84) — SpringBoard side ────────────────────────────────────
- (void)connect {
    [_clientSocket create:@"127.0.0.1" port:22222];
}

// ─── -isConnected ─────────────────────────────────────────────────────────────
- (BOOL)isConnected {
    return [_clientSocket isConnected];
}

// ─── VCamClientSocketDelegate ─────────────────────────────────────────────────

// readCallback: (0x8A7A0)
// Confirmed: processes NSData inline — NO _responseBuffer, NO parseResponse.
// Original reads bytes directly from a3 parameter, handles 1007/1012/1013/1015/1017.
- (void)readCallback:(NSData *)data {
    if (!data || ![data length]) return;

    const int32_t *bytes = (const int32_t *)[data bytes];
    int32_t code = bytes[0];

    if (code <= 1012) {
        if (code == 1007) {
            // Resolution: code(4) + width(4) + height(4)
            // Dispatch to main for delegate call (sub_8ABBC)
            int32_t width  = bytes[1];
            int32_t height = bytes[2];
            dispatch_async(dispatch_get_main_queue(), ^{
                // delegate resolution update (delegate may be nil — silent no-op)
                (void)width; (void)height;
            });
            return;
        }
        if (code != 1012) return;
        // 1012: fall through to error handler
    } else if (code == 1015) {
        // Login success
        [self setIsLogin:YES];
        [self setSeconds:[[NSDate date] timeIntervalSince1970]];
        [self saveCredentials];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentation];  // sub_8ABB4
        });
        return;
    } else if (code == 1013) {
        // Logout from server (sub_8AD24 + setLive/setSwitchFace)
        dispatch_async(dispatch_get_main_queue(), ^{
            // closeSwitch on delegate if available
        });
        [[VCamLiveManager sharedInstance] setLive:NO];
        [[VCamLiveManager sharedInstance] setSwitchFace:NO];
        return;
    } else if (code == 2001) {
        // Diagnostic packets from mediaserverd via vcamSendDiag.
        // Multiple packets may arrive in one recv() call — parse all of them.
        const uint8_t *rb = (const uint8_t *)[data bytes];
        NSUInteger total = [data length];
        NSUInteger off = 0;
        NSMutableArray *newParts = [NSMutableArray array];
        while (off + 8 <= total) {
            int32_t c2; memcpy(&c2, rb + off, 4);
            if (c2 != 2001) break;
            int32_t mlen; memcpy(&mlen, rb + off + 4, 4);
            if (mlen <= 0 || off + 8 + (NSUInteger)mlen > total) break;
            NSString *part = [[NSString alloc] initWithBytes:(rb + off + 8)
                                                      length:(NSUInteger)mlen
                                                    encoding:NSUTF8StringEncoding];
            if (part) {
                [newParts addObject:part];
                [part release];
            }
            off += 4 + 4 + (NSUInteger)mlen;
        }
        if ([newParts count] == 0) return;

        // Append new parts to g_vcamDiag (multi-line, max 10 lines).
        // Must happen on main queue since g_vcamDiag is main-queue-only.
        NSArray *snapshot = [newParts copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *lines = [NSMutableArray array];
            if (g_vcamDiag && [g_vcamDiag length] > 0) {
                [lines addObjectsFromArray:[g_vcamDiag componentsSeparatedByString:@"\n"]];
            }
            for (NSString *p in snapshot) [lines addObject:p];
            while ([lines count] > 20) [lines removeObjectAtIndex:0];
            NSString *updated = [[lines componentsJoinedByString:@"\n"] retain];
            [g_vcamDiag release];
            g_vcamDiag = updated;
            id menuVC = [VCamBridge sharedInstance].menuViewController;
            if (menuVC) [(VCamMenuViewController *)menuVC showDiag:g_vcamDiag];
            [snapshot release];
        });
        return;
    } else if (code != 1017) {
        return;  // unknown code > 1012, ignore
    }
    // Error handler: code 1012 or 1017
    // Format: code(4) + msgLen(4) + msg(msgLen)
    [self dismiss];
    NSData *msgData = [NSData dataWithBytes:(bytes + 2) length:(NSUInteger)bytes[1]];
    NSString *msg = [[NSString alloc] initWithData:msgData encoding:NSUTF8StringEncoding];
    NSString *msgCopy = [msg copy];
    [msg release];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@""
            message:msgCopy
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        UIViewController *root = [VCamBridge getRootViewController];
        if (root) [root presentViewController:alert animated:YES completion:nil];
        [msgCopy release];
    });
    [self stop];
    [self setIsLogin:NO];
    [self setUsername:nil];
    [self setPassword:nil];
    [[VCamLiveManager sharedInstance] setLive:NO];
}

// connectCallback (0x8A674) — confirmed 4-byte ret, genuine no-op in original binary
- (void)connectCallback { }

// ─── -send: (0x8AD98) — SpringBoard sends IPC to mediaserverd ────────────────
// All debug probes removed — they were added during debugging and are NOT in original.
- (void)send:(NSData *)data {
    [_clientSocket write:data];
}

// ─── -presentation (0x8AFF0) — show menu or close it if already open ─────────
- (void)presentation {
    if (self.isPresent) {
        // Float button tapped while menu is open → close the menu
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismiss];
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showMainMenu];
        });
    }
}

- (void)showMainMenu {
    // Create a dedicated UIWindow so the menu sits above all other apps.
    if (!s_menuWindow) {
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];

        // iOS 13+: UIWindows created with initWithFrame: inside SpringBoard are not
        // associated with a UIWindowScene. UIKit silently ignores presentViewController:
        // on such windows. Use initWithWindowScene: so presentation actually works.
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
            if (!scene) scene = (UIWindowScene *)s;
        }
        if (scene) {
            s_menuWindow = [[UIWindow alloc] initWithWindowScene:scene];
            s_menuWindow.frame = [UIScreen mainScreen].bounds;
        } else {
            s_menuWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }

        s_menuWindow.rootViewController = rootVC;
        [rootVC release];
        s_menuWindow.windowLevel = UIWindowLevelStatusBar + 5000.0;
        s_menuWindow.backgroundColor = [UIColor clearColor];
        s_menuWindow.opaque = NO;
    }
    s_menuWindow.hidden = NO;

    VCamMenuViewController *vc = [[VCamMenuViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle   = UIModalTransitionStyleCrossDissolve;
    [s_menuWindow.rootViewController presentViewController:vc animated:YES completion:^{
        self.menuViewController = vc;
        self.isPresent = YES;
    }];
    [vc release];
}

// ─── -sigin (0x88608 → sub_88660) — login dialog ────────────────────────────
// Confirmed: sub_88660 dispatches to main, loads vc.plist, shows UIAlertController.
// sub_88C28 (confirm handler): sets self.username/password FIRST, then sends 1014.
- (void)sigin {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *saved = [self loadCredentials];
        NSString *savedUser = saved[@"username"];
        NSString *savedPass = saved[@"password"];

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Login"
            message:nil
            preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Username";
            if (savedUser.length > 0) tf.text = savedUser;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Password";
            tf.secureTextEntry = YES;
            if (savedPass.length > 0) tf.text = savedPass;
        }];

        // Confirm action — sub_88C28:
        // 1. Set self.username = textField[0].text
        // 2. Set self.password = textField[1].text
        // 3. If either is empty → re-show sigin
        // 4. Build 1014 packet and send via [VCamBridge.sharedInstance send:]
        UIAlertAction *confirm = [UIAlertAction
            actionWithTitle:@"Confirm"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                self.username = alert.textFields[0].text;
                self.password = alert.textFields[1].text;
                if (!self.username.length || !self.password.length) {
                    [self sigin];
                    return;
                }

                const char *uStr = [self.username UTF8String];
                const char *pStr = [self.password UTF8String];
                int32_t uLen = (int32_t)strlen(uStr);
                int32_t pLen = (int32_t)strlen(pStr);
                int32_t payloadSize = uLen + pLen + 8;
                int32_t code = 1014;

                NSMutableData *packet = [NSMutableData dataWithCapacity:(NSUInteger)(16 + uLen + pLen)];
                [packet appendBytes:&code        length:4];
                [packet appendBytes:&payloadSize length:4];
                [packet appendBytes:&uLen        length:4];
                [packet appendBytes:uStr         length:(NSUInteger)uLen];
                [packet appendBytes:&pLen        length:4];
                [packet appendBytes:pStr         length:(NSUInteger)pLen];

                [[VCamBridge sharedInstance] send:packet];
            }];

        UIAlertAction *cancel = [UIAlertAction
            actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel
            handler:nil];

        [alert addAction:confirm];
        [alert addAction:cancel];

        UIViewController *root = [VCamBridge getRootViewController];
        if (root) [root presentViewController:alert animated:YES completion:nil];
    });
}

// ─── -dismiss (0x8B290) ───────────────────────────────────────────────────────
- (void)dismiss {
    if (!self.isPresent) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        VCamMenuViewController *vc = (VCamMenuViewController *)self.menuViewController;
        if (!vc) return;

        if ([vc respondsToSelector:@selector(animateDismissWithCompletion:)]) {
            [vc animateDismissWithCompletion:^{
                [vc dismissViewControllerAnimated:NO completion:^{
                    self.isPresent = NO;
                    self.menuViewController = nil;
                    if (s_menuWindow) s_menuWindow.hidden = YES;
                }];
            }];
        } else {
            [vc dismissViewControllerAnimated:YES completion:^{
                self.isPresent = NO;
                self.menuViewController = nil;
                if (s_menuWindow) s_menuWindow.hidden = YES;
            }];
        }
    });
}

// ─── -stop (0x8B3C0) ──────────────────────────────────────────────────────────
// Called at the start of code 1000 (LIVE ON) to reset delivery state before
// startServerLoop. stopDecoding is safe here because code 1001 (LIVE OFF) already
// called stopServer async — by the time code 1000 arrives, the server may be mid-teardown
// but stopDecoding on an already-stopped server is a no-op.
- (void)stop {
    vcamSendDiag(@"vcam:stop");
    self->_beginTimeYUV = 0.0;
    if ([self server]) {
        [[self server] stopDecoding];
    }
}

// ─── -parse:socketHandle: (0x899E0) — mediaserverd IPC dispatcher ─────────────
// All code mappings and packet sizes confirmed from IDA decompile.
- (void)parse:(NSMutableData *)buffer socketHandle:(int)socketHandle {
    while (buffer.length >= 4) {
        const uint8_t *bytes = (const uint8_t *)buffer.bytes;
        int32_t code = *(const int32_t *)bytes;

        if (code == 1000) {
            // Pause delivery (stop() → stopDecoding) but keep server/thread alive.
            [self stop];
            [[VCamLiveManager sharedInstance] setLiveUserIntent:YES];  // IPC intent tracking
            [[VCamLiveManager sharedInstance] setLive:YES];
            [[VCamLiveManager sharedInstance] setSwitchFace:NO];

            // Reuse existing server if alive — only create on first call.
            if (![self server]) {
                RTMPServer *srv = [[RTMPServer alloc] init];
                [self setServer:srv];
                [srv release];
                [[self server] setDelegate:self];
            }
            [self setServerThread:nil];  // informational only; thread managed inside RTMPServer

            RTMPServer *srvRef = [self server];

            // Retry up to 5 × 100ms — handles transient port-in-use on iOS 16.
            BOOL bindOK = NO;
            for (int _r = 0; _r < 5 && !bindOK; _r++) {
                bindOK = [RTMPServer createActiveTCPServer];
                if (!bindOK && _r < 4) usleep(100000);
            }

            if (!bindOK) {
                NSString *err = [RTMPServer lastBindError] ?: @"?";
                [_serverSocket sendAll:makeErrorPacket(2001,
                    [NSString stringWithFormat:@"1935:FAIL %@", err])];
            } else {
                [_serverSocket sendAll:makeErrorPacket(2001, @"1935:ok")];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [srvRef startServerLoop];
                });
            }

            [buffer replaceBytesInRange:NSMakeRange(0, 4) withBytes:NULL length:0];
        }
        else if (code == 1001) {
            [buffer replaceBytesInRange:NSMakeRange(0, 4) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setLiveUserIntent:NO];
            [[VCamLiveManager sharedInstance] setLive:NO];
            vcamSendDiag(@"LIVE->NO[1001]");
            // Full server stop: release port 1935 and drop OBS connection.
            // Dispatched async because stopServer blocks for ~1s (thread join sleep).
            RTMPServer *srv = [self server];
            if (srv) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [srv stopServer];
                });
            }
        }
        else if (code == 1002) {
            // Confirmed 0x89A8C: setThinFacePercent (NOT dermabrasion)
            if (buffer.length < 8) break;
            float val; memcpy(&val, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setThinFacePercent:val];
        }
        else if (code == 1003) {
            // Confirmed 0x89FF4: setBigEyePercent (NOT thinFace)
            if (buffer.length < 8) break;
            float val; memcpy(&val, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setBigEyePercent:val];
        }
        else if (code == 1004) {
            // Confirmed 0x89D28: 28 bytes (code(4) + 6×float(4))
            // floats[1]=thinFace, floats[2]=bigEye, floats[3]=bigNose,
            // floats[4]=bigMouth, floats[5]=dermabrasion, floats[6]=padding
            if (buffer.length < 28) break;
            const float *f = (const float *)(bytes + 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 28) withBytes:NULL length:0];
            VCamLiveManager *lm = [VCamLiveManager sharedInstance];
            [lm setThinFacePercent:f[0]];
            [lm setBigEyePercent:f[1]];
            [lm setBigNosePercent:f[2]];    // f[2]=floats[3]=bigNose (confirmed 0x89DB8)
            [lm setBigMouthPercent:f[3]];   // f[3]=floats[4]=bigMouth (confirmed 0x89D94)
            [lm setDermabrasionPercent:f[4]];
        }
        else if (code == 1005) {
            if (buffer.length < 8) break;
            int32_t val; memcpy(&val, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setSwitchFace:(val == 1)];
            if (val == 1) {
                vcamSendDiag(@"LIVE->NO[1005]");
                [[VCamLiveManager sharedInstance] setLive:NO];
                [self stop];
            }
        }
        else if (code == 1006) {
            // Confirmed 0x89FBC: setDermabrasionPercent (MISSING from previous builds)
            if (buffer.length < 8) break;
            float val; memcpy(&val, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setDermabrasionPercent:val];
        }
        else if (code == 1008) {
            // Confirmed 0x89D20: setBigNosePercent (NOT bigEye)
            if (buffer.length < 8) break;
            float val; memcpy(&val, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setBigNosePercent:val];
        }
        else if (code == 1009) {
            // Confirmed 0x89AEC: setBigMouthPercent (NOT bigNose)
            if (buffer.length < 8) break;
            float val; memcpy(&val, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setBigMouthPercent:val];
        }
        else if (code == 1014 || code == 1016) {
            // Login (1014) / Re-check (1016): code(4)+payloadSize(4)+uLen(4)+user+pLen(4)+pass
            if (buffer.length < 8) break;
            int32_t payloadSize; memcpy(&payloadSize, bytes + 4, 4);
            if (payloadSize < 0 || payloadSize > 0x400) {
                [self remove:socketHandle]; return;
            }
            NSUInteger totalLen = (NSUInteger)(8 + payloadSize);
            if (buffer.length < totalLen) break;

            NSString *user = nil, *pass = nil;
            if (payloadSize >= 8) {
                int32_t uLen; memcpy(&uLen, bytes + 8, 4);
                if (uLen >= 0 && uLen <= 0x100 && payloadSize >= uLen + 8) {
                    user = [[NSString alloc] initWithBytes:(bytes + 12)
                                                    length:(NSUInteger)uLen
                                                  encoding:NSUTF8StringEncoding];
                    int32_t pLen; memcpy(&pLen, bytes + 12 + uLen, 4);
                    if (pLen >= 0 && pLen <= 0x100 && payloadSize >= uLen + pLen + 8) {
                        pass = [[NSString alloc] initWithBytes:(bytes + 12 + uLen + 4)
                                                        length:(NSUInteger)pLen
                                                      encoding:NSUTF8StringEncoding];
                    }
                }
            }
            [buffer replaceBytesInRange:NSMakeRange(0, totalLen) withBytes:NULL length:0];

            if (user && pass) {
                self.username = user;
                self.password = pass;
                if (code == 1014) {
                    [self login:user password:pass];
                } else {
                    [self check:user password:pass];
                }
            } else {
                [self remove:socketHandle]; return;
            }
            [user release];
            [pass release];
        }
        else if (code == 1018) {
            if (buffer.length < 8) break;
            int32_t pos; memcpy(&pos, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setCameraSelected:pos];   // IDA: passes raw int directly
        }
        else if (code == 1019) {
            // RTMP rotation angle: -1=Auto, 0=0°, 90=90°, 180=180°, 270=270°.
            // Sent by SpringBoard menu when user changes the rotation segment.
            if (buffer.length < 8) break;
            int32_t angle; memcpy(&angle, bytes + 4, 4);
            [buffer replaceBytesInRange:NSMakeRange(0, 8) withBytes:NULL length:0];
            [[VCamLiveManager sharedInstance] setRTMPRotation:(int)angle];
        }
        else {
            // Unknown code — confirmed LABEL_52 at 0x8A1E0:
            // [self remove:socketHandle]; return
            [self remove:socketHandle];
            return;
        }
    }
}

// ─── -remove: (0x89084) ───────────────────────────────────────────────────────
// Confirmed: removes mapTable entry, then [serverSocket close:fd].
// Original also calls free([buffer pointerValue]) but we use NSMutableData not
// malloc'd C structs, so no free needed.
- (void)remove:(int)socketHandle {
    @synchronized(self) {
        [_mapTable removeObjectForKey:@(socketHandle)];
    }
    [_serverSocket close:socketHandle];   // IDA method name: close: (not remove:)
}

// ─── -login:password: (0x891A0) — HTTP login via sharedInstance ───────────────
// Confirmed: uses [iCdfsIdfdEdfsNdfdftqWer sharedInstance], NOT a local instance.
// sharedInstance.token is set on success by VCamNetworkRequest.
// Token is read by parse: code 1000 before starting RTMP server.
- (void)login:(NSString *)username password:(NSString *)password {
    iCdfsIdfdEdfsNdfdftqWer *req = [iCdfsIdfdEdfsNdfdftqWer sharedInstance];
    // setUrl: is intercepted by NetHelper hook → always redirected to kkameugojm.catto.lol
    [req setUrl:@"kkameugojm.catto.lol"];

    __block ServerSocket *sock = _serverSocket;

    [req login:username password:password callback:^(BOOL success, NSString *message) {
        NSData *response;
        if (success) {
            int32_t code = 1015;
            response = [NSData dataWithBytes:&code length:4];
        } else {
            NSString *msg = message ?: @"Login failed";
            response = makeErrorPacket(1012, msg);
        }
        [sock sendAll:response];
    }];
}

// ─── -check:password: (0x895D8) ───────────────────────────────────────────────
// IDA: independent HTTP call (not a forwarder to login:).
// On failure: error code 1017 (not 1012 which login: uses).
- (void)check:(NSString *)username password:(NSString *)password {
    iCdfsIdfdEdfsNdfdftqWer *req = [iCdfsIdfdEdfsNdfdftqWer sharedInstance];
    [req setUrl:@"kkameugojm.catto.lol"];

    __block ServerSocket *sock = _serverSocket;

    [req login:username password:password callback:^(BOOL success, NSString *message) {
        NSData *response;
        if (success) {
            int32_t code = 1015;
            response = [NSData dataWithBytes:&code length:4];
        } else {
            NSString *msg = message ?: @"Login failed";
            response = makeErrorPacket(1017, msg);   // 1017 for re-check, not 1012
        }
        [sock sendAll:response];
    }];
}

// ─── Credential persistence (used by readCallback: code 1015) ─────────────────
// Original saves via NSFileManager URLsForDirectory:inDomains: to Documents/vc.plist
- (void)saveCredentials {
    if (!self.username || !self.password) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *urls = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *docUrl = [urls firstObject];
    if (!docUrl) return;
    NSString *path = [[docUrl URLByAppendingPathComponent:@"vc.plist"] path];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionaryWithCapacity:1];
    [d setObject:self.username forKey:@"username"];
    [d setObject:self.password forKey:@"password"];
    [d writeToFile:path atomically:YES];
}

- (NSDictionary *)loadCredentials {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *urls = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *docUrl = [urls firstObject];
    if (!docUrl) return nil;
    NSString *path = [[docUrl URLByAppendingPathComponent:@"vc.plist"] path];
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

// ─── -getKeyWindow / -getRootViewController ───────────────────────────────────
+ (UIWindow *)getKeyWindow {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow) return w;
    }
    return nil;
}

+ (UIViewController *)getRootViewController {
    UIWindow *w = [VCamBridge getKeyWindow];
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ─── -startThread / -run (0x88394 / 0x88404) ─────────────────────────────────
// run: confirmed sleep(0x78=120s) + while loop + send 1016 packet
// startThread: confirmed creates NSThread running run, stores in self.thread
// NOTE: startThread has NO callsites in original binary — not called internally.
- (void)startThread {
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    self.thread = t;
    [t start];
    [t release];
}

- (void)run {
    while (1) {
        sleep(0x78);  // 120 seconds
        NSString *user = [self username];
        while (!user) { user = [self username]; }  // spin until username is set
        NSString *pass = [self password];
        if (!pass) continue;
        if ([self isConnected]) {
            // Build 1016 packet: code(4)+payloadSize(4)+uLen(4)+user+pLen(4)+pass
            const char *uStr = [user UTF8String];
            const char *pStr = [pass UTF8String];
            int32_t uLen = (int32_t)strlen(uStr);
            int32_t pLen = (int32_t)strlen(pStr);
            int32_t payloadSize = uLen + pLen + 8;
            int32_t code = 1016;

            NSMutableData *packet = [NSMutableData dataWithCapacity:(NSUInteger)(16 + uLen + pLen)];
            [packet appendBytes:&code        length:4];
            [packet appendBytes:&payloadSize length:4];
            [packet appendBytes:&uLen        length:4];
            [packet appendBytes:uStr         length:(NSUInteger)uLen];
            [packet appendBytes:&pLen        length:4];
            [packet appendBytes:pStr         length:(NSUInteger)pLen];

            [[VCamBridge sharedInstance] send:packet];
        }
    }
}

// ─── -setSpringBoard: ─────────────────────────────────────────────────────────
- (void)setSpringBoard:(id)sb {
    _springBoard = sb;
}

// ─── -setResolution:height: ───────────────────────────────────────────────────
// IDA: unconditional send — params are unsigned int (not size_t).
// Rate-limiting is handled by the MediaServerHooks caller (g_lastResolutionUpdate check there).
- (void)setResolution:(unsigned int)width height:(unsigned int)height {
    int32_t buf[3] = {1007, (int32_t)width, (int32_t)height};
    [_serverSocket sendAll:[NSData dataWithBytes:buf length:12]];
}

// imageBufferToSampleBuffer:timeStamp: (IDA 0x88F1C)
// Wraps a CVPixelBuffer into a CMSampleBuffer with PTS derived from _beginTimeYUV.
// timescale=600: each tick is 1/600s; beginTimeYUV*600 gives unique, monotonically
// increasing PTS values used for dedup in modifyImageBuffer:.
- (CMSampleBufferRef)imageBufferToSampleBuffer:(CVImageBufferRef)imageBuffer
                                     timeStamp:(double)ts
{
    if (!imageBuffer) return NULL;

    CVPixelBufferLockBaseAddress((CVPixelBufferRef)imageBuffer, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus fmtErr = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, imageBuffer, &fmt);
    if (fmtErr != noErr) {
        CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)imageBuffer, 0);
        return NULL;
    }

    CMSampleTimingInfo timing;
    memset(&timing, 0, sizeof(timing));
    timing.presentationTimeStamp.timescale = 600;
    timing.presentationTimeStamp.flags     = kCMTimeFlags_Valid;
    timing.presentationTimeStamp.value     = (int64_t)(ts * 600.0);

    CMSampleBufferRef sbuf = NULL;
    OSStatus sbufErr = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        imageBuffer,
        YES, NULL, NULL,
        fmt, &timing, &sbuf);

    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)imageBuffer, 0);

    if (fmt) CFRelease(fmt);

    if (sbufErr != noErr) {
        if (sbuf) CFRelease(sbuf);
        return NULL;
    }
    return sbuf;
}

// ─── RTMPServerDelegate (IDA 0x89010) — decoded H.264 frames from RTMP ───────
// IDA-confirmed: wraps CVPixelBuffer → CMSampleBuffer → setYUVSampleBuffer:.
// This ensures modifyImageBuffer: reads _liveYUVSampleBuffer (IDA-confirmed path)
// rather than _pixelYUVBuffer (the divergent fast-path used in v2.110–v2.113).
// Both the CMSampleBufferCreateCopy in setYUVSampleBuffer: AND the
// VTImageRotationSessionTransferImage for _pixelYUVBuffer90 happen under _lock,
// preventing concurrent VT hardware use with the camera thread.
- (void)outputFrame:(void *)frameData
 presentationTimeStamp:(int64_t)pts
  presentationDuration:(int64_t)duration
{
    if (!frameData) return;
    CVImageBufferRef src = (CVImageBufferRef)frameData;

    CMSampleBufferRef sbuf = [self imageBufferToSampleBuffer:src
                                                   timeStamp:self.beginTimeYUV];
    if (sbuf) {
        [[VCamLiveManager sharedInstance] setYUVSampleBuffer:sbuf];
        CFRelease(sbuf);
    }
    self.beginTimeYUV += 20.0;
}

// ─── Output stubs ─────────────────────────────────────────────────────────────
- (void)outputVideo:(void *)data sps_size:(int)spsSize pps:(void *)pps pps_size:(int)ppsSize {}
- (void)outputVideo:(void *)data size:(int)size {}
- (void)endOfOutput {}

@end
