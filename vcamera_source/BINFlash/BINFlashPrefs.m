// BINFlashPrefs.m
// Unified prefs implementation — BINFlashAddon bit packing + 100ms read cache.

#import "BINFlashPrefs.h"
#import <notify.h>
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static NSArray<NSString *> *_plistPaths(void) {
    return @[
        @"/var/mobile/Library/Preferences/com.meo.flashaddon.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.meo.flashaddon.plist",
        @"/var/tmp/com.meo.flashaddon.plist",
        @"/tmp/com.meo.flashaddon.plist",
    ];
}

// Bit layout (sub_89C4 from BINFlashAddon):
//   bit  63: dirty flag
//   bit   0: live
//   bit   1: flash
//   bit   2: manualRegion
//   bits 3-12: speed × 10
//   bits13-19: brightness int
//   bits20-26: region int
//   bits27-36: hue × 1000
//   bits37-46: regionX × 1000
//   bits47-56: regionY × 1000
#define kNotifyDirtyBit 0x8000000000000000ULL

static NSDictionary *_unpackState(uint64_t s) {
    BOOL live         = (s & 1) != 0;
    BOOL flash        = (s & 2) != 0;
    BOOL manualRegion = (s & 4) != 0;
    double speed      = ((s >> 3) & 0x3FF) / 10.0;
    int brightness    = (int)((s >> 13) & 0x7F);
    int region        = (int)((s >> 20) & 0x7F);
    double hue        = ((s >> 27) & 0x3FF) / 1000.0;
    double regionX    = ((s >> 37) & 0x3FF) / 1000.0;
    double regionY    = ((s >> 47) & 0x3FF) / 1000.0;

    return @{
        kBINFlashKeyLive:         @(live),
        kBINFlashKeyFlash:        @(flash),
        kBINFlashKeyManualRegion: @(manualRegion),
        kBINFlashKeySpeed:        @(speed),
        kBINFlashKeyBrightness:   @(brightness),
        kBINFlashKeyRegion:       @(region),
        kBINFlashKeyHue:          @(hue),
        kBINFlashKeyRegionX:      @(regionX),
        kBINFlashKeyRegionY:      @(regionY),
    };
}

// ── Read cache (for per-frame calls in mediaserverd) ──
static NSDictionary     *s_cachedPrefs     = nil;
static CFAbsoluteTime    s_cacheTimestamp  = 0;
static int               s_notifyToken     = 0;
static dispatch_once_t   s_notifyOnce      = 0;

NSDictionary *BINFlashLoadPrefs(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // 100ms cache hit
    if (s_cachedPrefs && (now - s_cacheTimestamp) < kBINFlashPrefsCacheTTL) {
        return s_cachedPrefs;
    }

    // Register notify token once
    dispatch_once(&s_notifyOnce, ^{
        notify_register_check(kBINFlashNotifyChannel, &s_notifyToken);
    });

    // Start with defaults
    NSMutableDictionary *result = [@{
        kBINFlashKeyLive:         @(kBINFlashDefaultLive),
        kBINFlashKeyFlash:        @(kBINFlashDefaultFlash),
        kBINFlashKeyManualRegion: @(kBINFlashDefaultManualRegion),
        kBINFlashKeySpeed:        @(kBINFlashDefaultSpeed),
        kBINFlashKeyBrightness:   @(kBINFlashDefaultBrightness),
        kBINFlashKeyRegion:       @(kBINFlashDefaultRegion),
        kBINFlashKeyHue:          @(kBINFlashDefaultHue),
        kBINFlashKeyRegionX:      @(kBINFlashDefaultRegionX),
        kBINFlashKeyRegionY:      @(kBINFlashDefaultRegionY),
        kBINFlashKeyAutoColor:    @(kBINFlashDefaultAutoColor),
        kBINFlashKeyStaticFlash:  @(kBINFlashDefaultStaticFlash),
    } mutableCopy];

    // Try plist paths
    for (NSString *path in _plistPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (d) { [result addEntriesFromDictionary:d]; break; }
    }

    // Try notify state (zero-latency override)
    if (s_notifyToken) {
        uint64_t state = 0;
        if (notify_get_state(s_notifyToken, &state) == NOTIFY_STATUS_OK) {
            if (state & kNotifyDirtyBit) {
                [result addEntriesFromDictionary:_unpackState(state)];
            }
        }
    }

    s_cachedPrefs    = [result copy];
    s_cacheTimestamp = now;
    return s_cachedPrefs;
}

// ── BINFlashSavePrefs (SpringBoard side only) ──

static void _packAndSetState(NSDictionary *prefs) {
    static int s_writeToken = 0;
    static dispatch_once_t s_writeOnce = 0;
    dispatch_once(&s_writeOnce, ^{
        notify_register_check(kBINFlashNotifyChannel, &s_writeToken);
    });
    if (!s_writeToken) return;

    BOOL live         = BINFlashBoolForKey(prefs, kBINFlashKeyLive,         kBINFlashDefaultLive);
    BOOL flash        = BINFlashBoolForKey(prefs, kBINFlashKeyFlash,        kBINFlashDefaultFlash);
    BOOL manualRegion = BINFlashBoolForKey(prefs, kBINFlashKeyManualRegion, kBINFlashDefaultManualRegion);
    double speed      = BINFlashDoubleForKey(prefs, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);
    double brightness = BINFlashDoubleForKey(prefs, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    double region     = BINFlashDoubleForKey(prefs, kBINFlashKeyRegion,     kBINFlashDefaultRegion);
    double hue        = BINFlashDoubleForKey(prefs, kBINFlashKeyHue,        kBINFlashDefaultHue);
    double regionX    = BINFlashDoubleForKey(prefs, kBINFlashKeyRegionX,    kBINFlashDefaultRegionX);
    double regionY    = BINFlashDoubleForKey(prefs, kBINFlashKeyRegionY,    kBINFlashDefaultRegionY);

    uint64_t s = kNotifyDirtyBit;
    if (live)         s |= 1;
    if (flash)        s |= 2;
    if (manualRegion) s |= 4;
    s |= ((uint64_t)(llround(fmax(fmin(speed, 102.3), 0.0) * 10.0)) * 8) & 0x1FF8ULL;
    s |= ((uint64_t)(llround(fmax(fmin(brightness, 100.0), 0.0))) << 13) & 0xFE000ULL;
    s |= ((uint64_t)(llround(fmax(fmin(region,     100.0), 0.0))) << 20) & 0x7F00000ULL;
    s |= ((uint64_t)(llround(fmax(fmin(hue,    1.0), 0.0) * 1000.0) & 0x3FF) << 27);
    s |= ((uint64_t)(llround(fmax(fmin(regionX,1.0), 0.0) * 1000.0) & 0x3FF) << 37);
    s |= ((uint64_t)(llround(fmax(fmin(regionY,1.0), 0.0) * 1000.0) & 0x3FF) << 47);

    notify_set_state(s_writeToken, s);
}

void BINFlashSavePrefs(NSDictionary *newValues) {
    NSMutableDictionary *merged = [BINFlashLoadPrefs() mutableCopy];
    if ([newValues isKindOfClass:[NSDictionary class]])
        [merged addEntriesFromDictionary:newValues];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in _plistPaths()) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [merged writeToFile:path atomically:YES];
        [fm setAttributes:@{NSFilePosixPermissions: @(420)} ofItemAtPath:path error:nil];
    }

    _packAndSetState(merged);
    notify_post(kBINFlashNotifyChannel);

    // Invalidate cache immediately so next read sees new values
    s_cachedPrefs    = nil;
    s_cacheTimestamp = 0;
}

BOOL BINFlashBoolForKey(NSDictionary *prefs, NSString *key, BOOL defaultValue) {
    id val = prefs[key];
    if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
    return defaultValue;
}

double BINFlashDoubleForKey(NSDictionary *prefs, NSString *key, double defaultValue) {
    id val = prefs[key];
    if ([val respondsToSelector:@selector(doubleValue)]) return [val doubleValue];
    return defaultValue;
}
