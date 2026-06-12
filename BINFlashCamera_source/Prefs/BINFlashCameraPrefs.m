// BINFlashCameraPrefs.m
// Reconstructed from:
//   sub_539C  (0x539C) — prefs loader with 100ms TTL cache
//   sub_5DA4  (0x5DA4) — double dict getter (mirrors BINFlashAddon sub_72F0)
//   sub_5EB8  (0x5EB8) — bool dict getter  (mirrors BINFlashAddon sub_7258)
//   stru_8080          — dispatch_once block: notify_register_check

#import "BINFlashCameraPrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

// Prefs 4-path fallback (same as BINFlashAddon — rootful + rootless jailbreak)
static NSArray<NSString *> *BINFlashCameraPlistPaths(void) {
    return @[
        @"/var/mobile/Library/Preferences/com.meo.flashaddon.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.meo.flashaddon.plist",
        @"/var/tmp/com.meo.flashaddon.plist",
        @"/tmp/com.meo.flashaddon.plist",
    ];
}

// ── 64-bit packed state unpacking (same layout as BINFlashAddon sub_89C4) ──
//
// Bit layout of packed uint64 (set by BINFlashAddon via notify_set_state):
//   [63]     dirty flag (1 = state is valid)
//   [62:61]  reserved
//   [60:50]  live       (1-bit bool packed as 11-bit field)
//   [49:39]  flash      (1-bit bool)
//   [38:28]  speed      (float × 10, 11 bits, range 0–200)
//   [27:18]  brightness (float, 10 bits, range 0–100)
//   [17:8]   region     (float, 10 bits, range 0–100)
//   [7:0]    hue        (float × 100, 8 bits, range 0–100)
//
// Note: the exact bit widths are reconstructed from sub_89C4 shift + mask pattern.
// The dirty flag (bit 63) must be set for the packed state to be used.

static void BINFlashCameraUnpackState(uint64_t state, NSMutableDictionary *prefs) {
    if (!(state & (1ULL << 63))) return;  // dirty flag not set → ignore

    BOOL live       = (state >> 60) & 0x1;
    BOOL flash      = (state >> 59) & 0x1;
    double speed      = ((state >> 48) & 0x7FF) / 10.0;
    double brightness = ((state >> 38) & 0x3FF) / 10.0;
    double region     = ((state >> 28) & 0x3FF) / 10.0;
    double hue        = ((state >> 20) & 0xFF)  / 100.0;
    BOOL manualRegion = (state >> 19) & 0x1;
    double regionX    = ((state >> 10) & 0x1FF) / 100.0;
    double regionY    = ( state        & 0x3FF) / 100.0;

    prefs[kBINFlashKeyLive]         = @(live);
    prefs[kBINFlashKeyFlash]        = @(flash);
    prefs[kBINFlashKeySpeed]        = @(speed);
    prefs[kBINFlashKeyBrightness]   = @(brightness);
    prefs[kBINFlashKeyRegion]       = @(region);
    prefs[kBINFlashKeyHue]          = @(hue);
    prefs[kBINFlashKeyManualRegion] = @(manualRegion);
    prefs[kBINFlashKeyRegionX]      = @(regionX);
    prefs[kBINFlashKeyRegionY]      = @(regionY);
}

// ── Global cache (qword_C2F8, qword_C300, byte_C308) ──
static NSDictionary *s_cachedPrefs     = nil;
static CFAbsoluteTime s_cacheTimestamp = 0;
static int            s_notifyToken    = 0;
static dispatch_once_t s_notifyOnce    = 0;  // stru_8080

// ── sub_539C ──
NSDictionary *BINFlashCameraLoadPrefs(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // 100ms cache hit: return without re-reading
    if (s_cachedPrefs && (now - s_cacheTimestamp) < kBINFlashCameraPrefsCacheTTL) {
        return s_cachedPrefs;
    }

    // dispatch_once: register Darwin notify token (stru_8080 block)
    dispatch_once(&s_notifyOnce, ^{
        notify_register_check(kBINFlashCameraNotifyKey, &s_notifyToken);
    });

    // Default prefs
    NSMutableDictionary *prefs = [@{
        kBINFlashKeyLive         : @(kBINFlashDefaultLive),
        kBINFlashKeyFlash        : @(kBINFlashDefaultFlash),
        kBINFlashKeySpeed        : @(kBINFlashDefaultSpeed),
        kBINFlashKeyBrightness   : @(kBINFlashDefaultBrightness),
        kBINFlashKeyRegion       : @(kBINFlashDefaultRegion),
        kBINFlashKeyHue          : @(kBINFlashDefaultHue),
        kBINFlashKeyManualRegion : @(kBINFlashDefaultManualRegion),
        kBINFlashKeyRegionX      : @(kBINFlashDefaultRegionX),
        kBINFlashKeyRegionY      : @(kBINFlashDefaultRegionY),
    } mutableCopy];

    // Try 4 plist paths
    for (NSString *path in BINFlashCameraPlistPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (d) {
            [prefs addEntriesFromDictionary:d];
            break;
        }
    }

    // Read Darwin notify state (zero-latency — from kernel notify table)
    uint64_t state64 = 0;
    if (notify_get_state(s_notifyToken, &state64) == NOTIFY_STATUS_OK) {
        BINFlashCameraUnpackState(state64, prefs);
    }

    s_cachedPrefs     = [prefs copy];
    s_cacheTimestamp  = now;
    return s_cachedPrefs;
}

// ── sub_5DA4 — double dict getter ──
double BINFlashCameraDoubleForKey(NSDictionary *prefs, NSString *key, double def) {
    id val = prefs[key];
    if (!val) return def;
    if ([val respondsToSelector:@selector(doubleValue)]) return [val doubleValue];
    return def;
}

// ── sub_5EB8 — bool dict getter ──
BOOL BINFlashCameraBoolForKey(NSDictionary *prefs, NSString *key, BOOL def) {
    id val = prefs[key];
    if (!val) return def;
    if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
    return def;
}
