// Tweak.x
// Reconstructed from sub_4000 (0x4000) — __init_offsets constructor
//
// NetHelper.dylib purpose:
//   Redirect all network requests from "apps.bkatm.com" (official backend)
//   to "bibq.net" (VIP cracked backend), while detecting and evading Frida.
//
// Hook mechanism: MSHookMessageEx on NSURL class method + one custom ObjC class.
// Anti-debug: dlsym check for Frida symbols at startup + 5s periodic exit(0).

#import "../Hooks/NetHelperHooks.h"
#import <substrate.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

// ── Guard globals (byte_C068, byte_C06C, dword_C070) ──
BOOL g_fridaDetected = NO;   // byte_C068: 1 = Frida present, hooks disabled
BOOL g_guardFlag     = NO;   // byte_C06C: secondary disable flag
int  g_urlCallCount  = 0;    // dword_C070: URLWithString: invocation counter

// ── Anti-Frida detection ──
// Checks for frida-gadget/frida-agent symbols in all loaded images.
// On iOS/macOS, RTLD_DEFAULT = (void*)-2 — searches all loaded images.
static BOOL NetHelper_IsFridaPresent(void) {
    char sym1[32], sym2[32];
    strcpy(sym1, "frida_agent_main");
    strcpy(sym2, "gum_init_embedded");
    return (dlsym((void *)(-2), sym1) != NULL || dlsym((void *)(-2), sym2) != NULL);
}

// ── sub_4000 ──
__attribute__((constructor))
static void NetHelper_Init(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (NetHelper_IsFridaPresent()) {
        // Frida is attached: disable URL hooks and let the app use the real server.
        // The 5-second timer (started below) will call exit(0) shortly after.
        g_fridaDetected = YES;
        g_guardFlag     = YES;
        // Fall through to set up timer — it will exit(0) on first tick
    }

    // 5-second anti-Frida timer
    dispatch_queue_t q = dispatch_queue_create("net.helper.guard", NULL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);

    // initial=5s (5,000,000,000 ns), interval=5s (0x12A05F200 ns), leeway=100ms
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, 5000000000LL),
        0x12A05F200ULL,
        0x5F5E100ULL);

    dispatch_source_set_event_handler(timer, ^{
        NetHelperTimerTick();
    });
    dispatch_resume(timer);

    if (!g_fridaDetected) {
        // Install URL hooks
        NetHelperInstallHooks();

        // Initialize guards to disabled state
        g_fridaDetected = NO;
        g_guardFlag     = NO;
        g_urlCallCount  = 0;
    }

    [pool drain];
}
