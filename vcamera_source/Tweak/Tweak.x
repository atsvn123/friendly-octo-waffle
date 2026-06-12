// Tweak.x — MobileSubstrate entry point for vcamera.dylib
// Reconstructed from IDA decompilation of sub_850FC (0x850FC), sub_852B4 (0x852B4), sub_86A4C (0x86A4C)
// All 4 constructors in __init_offsets (0xADDA0): 0x850FC, 0x85264 (nop), 0x852B4, 0x86A4C

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <dlfcn.h>
#import <pthread.h>
#import <mach-o/dyld.h>
#import "include/MobileGestalt.h"
#import "VCamBridge/VCamBridge.h"
#import "VCamLive/VCamLiveManager.h"
#import "Hooks/MediaServerHooks.h"
#import "Hooks/SpringBoardHooks.h"
#import "UI/VCamFloatButton.h"
#import "UI/VCamColorSampleListener.h"
#import "BINFlash/BINFlashCameraHooks.h"

// Global thread handles (from binary globals 0x1303A0, 0x1303A8)
static pthread_t assistiveThread;
static pthread_t listenThread;

// --- Thread entry points ---

// mediaserverd: starts IPC server (0x85094 = fTaqadKfwromsnd)
static void *listenThreadEntry(void *arg) {
    VCamBridge *bridge = [VCamBridge sharedInstance];
    [bridge listen];   // blocks — ServerSocket on port 22222
    return NULL;
}

// springboard: connects to IPC server and drives float button (0x84C40 = fTaqaTecczndwop)
// After connecting, loops forever dispatching vcamUpdateFloatButton() to main queue
// every 200ms while on homescreen, or every 600ms otherwise.
// Mirrors IDA fTaqaTecczndwop exactly — the float button only appears while this
// loop is running AND isConnected==YES AND g_menuReady==1.
static void *connectThreadEntry(void *arg) {
    sleep(3);   // initial wait for mediaserverd to be ready
    VCamBridge *bridge = [VCamBridge sharedInstance];
    [bridge connect];

    // Infinite loop — drives float button display (IDA confirmed)
    while ((g_done & 1) == 0) {
        if ([bridge isConnected]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                vcamUpdateFloatButton();
            });
            usleep(200000);  // 200ms
        } else {
            usleep(600000);  // 600ms
        }
    }
    return NULL;
}

// dyld image add callback (0x850D4 = _dyld_image_added)
static void dyldImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    dladdr(mh, &info);  // locate this dylib's own base address
}

// --- Constructor 1: sub_850FC (0x850FC) — Primary entry point ---
__attribute__((constructor))
static void vcamConstructorMain(void) {
    // Register dyld image callback
    _dyld_register_func_for_add_image(dyldImageAdded);

    // Determine which process we are injected into
    NSString *processName = [[[NSProcessInfo processInfo] processName] lowercaseString];

    if ([processName rangeOfString:@"springboard"].location != NSNotFound) {
        // SpringBoard: connect to mediaserverd IPC server
        pthread_create(&assistiveThread, NULL, connectThreadEntry, NULL);

    } else if ([processName rangeOfString:@"mediaserverd"].location != NSNotFound) {
        // mediaserverd: read device identity for license check
        NSString *serial = [NSString stringWithFormat:@"%@", MGCopyAnswer(CFSTR("SerialNumber"))];
        NSString *deviceKey = [NSString stringWithFormat:@"%@", MGCopyAnswer(CFSTR("k5lVWbXuiZHLA17KGiVUAA"))];
        (void)serial; (void)deviceKey;  // stored in globals

        // Start IPC listen server
        pthread_create(&listenThread, NULL, listenThreadEntry, NULL);
    }
}

// --- Constructor 2: sub_85264 (0x85264) — no-op ---
// (empty function, reconstructed as empty constructor)

// --- Constructor 3: sub_852B4 (0x852B4) — Install MSHookMessageEx hooks (process-specific) ---
__attribute__((constructor))
static void vcamInstallHooks(void) {
    NSString *pn = [[[NSProcessInfo processInfo] processName] lowercaseString];
    if ([pn rangeOfString:@"mediaserverd"].location != NSNotFound ||
        [pn rangeOfString:@"lskdd"].location != NSNotFound) {
        installMediaServerHooks();
        installBINFlashMediaHooks();
    } else if ([pn rangeOfString:@"springboard"].location != NSNotFound) {
        installSpringBoardHooks();
    } else {
        // Frontmost UIKit app (TikTok, camera apps, etc.) —
        // register color sample listener so SpringBoard can request
        // pixel colors from this app's rendered screen content.
        vcamInstallColorSampleListener();
    }
}

// --- Constructor 4: sub_86A4C (0x86A4C) — Register process cleanup via __cxa_atexit ---
// IDA: __cxa_atexit(sub_85268, 0, &dword_0)
// sub_85268: sets byte_130150 (g_done)=1, pthread_cancel(assistiveThread/listenThread)
// g_done (byte_130150) is declared in VCamBridge.h

static void vcamCleanup(void) {
    g_done = 1;
    if (assistiveThread) { pthread_cancel(assistiveThread); assistiveThread = 0; }
    if (listenThread)    { pthread_cancel(listenThread);    listenThread = 0; }
}

__attribute__((constructor))
static void vcamRegisterCleanup(void) {
    atexit(vcamCleanup);
}
