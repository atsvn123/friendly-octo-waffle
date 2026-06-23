// BINFlashPrefs.m
// Reconstructed from sub_6CDC (0x6CDC), sub_7258 (0x7258), sub_72F0 (0x72F0),
// sub_7E78 (0x7E78), sub_89C4 (0x89C4)

#import "BINFlashPrefs.h"
#import <notify.h>
#import <math.h>

// --- Plist search paths (sub_6CDC / sub_7E78 both use these 4 paths) ---
// Ordered: rootful jailbreak → rootless/Dopamine → /var/tmp → /tmp
static NSArray<NSString *> *_plistPaths(void) {
    return @[
        @"/var/mobile/Library/Preferences/com.meo.flashaddon.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.meo.flashaddon.plist",
        @"/var/tmp/com.meo.flashaddon.plist",
        @"/tmp/com.meo.flashaddon.plist",
    ];
}

// --- 64-bit state bit layout (sub_89C4) ---
// bit 63   : dirty flag (always 1 when written)
// bit  0   : live
// bit  1   : flash
// bit  2   : manualRegion
// bits 3-12: speed × 10 (10-bit, mask 0x1FF8)
// bits13-19: brightness int (7-bit, mask 0xFE000)
// bits20-26: region int (7-bit, mask 0x7F00000)
// bits27-36: hue × 1000 (10-bit)
// bits37-46: regionX × 1000 (10-bit)
// bits47-56: regionY × 1000 (10-bit)
#define kNotifyDirtyBit 0x8000000000000000ULL

// Unpack a 64-bit state into an NSDictionary (used by sub_6CDC when dirty bit is set)
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

// --- sub_6CDC (0x6CDC) ---
// Load prefs. Priority: Darwin notify state (if dirty bit set) > first valid plist.
NSDictionary *BINFlashLoadPrefs(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // Try all 4 plist paths; use the first that loads a valid dict
    for (NSString *path in _plistPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (d) {
            [result addEntriesFromDictionary:d];
            break;
        }
    }

    // Check Darwin notify state; if dirty bit is set, decode in-memory state
    int token = 0;
    if (notify_register_check(kBINFlashNotifyChannel, &token) == NOTIFY_STATUS_OK) {
        uint64_t state = 0;
        if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) {
            if (state & kNotifyDirtyBit) {
                // In-memory state overrides whatever was in the plist
                NSDictionary *live = _unpackState(state);
                [result addEntriesFromDictionary:live];
            }
        }
        notify_cancel(token);
    }

    return [result copy];
}

// --- sub_7258 (0x7258) ---
BOOL BINFlashBoolForKey(NSDictionary *prefs, NSString *key, BOOL defaultValue) {
    id val = prefs[key];
    if ([val respondsToSelector:@selector(boolValue)])
        return [val boolValue];
    return defaultValue;
}

// --- sub_72F0 (0x72F0) ---
double BINFlashDoubleForKey(NSDictionary *prefs, NSString *key, double defaultValue) {
    id val = prefs[key];
    if ([val respondsToSelector:@selector(doubleValue)])
        return [val doubleValue];
    return defaultValue;
}

// --- sub_89C4 (0x89C4) ---
// Encode current prefs into 64-bit state and call notify_set_state.
// Called by BINFlashSavePrefs after writing the plist.
static void _packAndSetState(NSDictionary *prefs) {
    // dispatch_once: register notify token once (token stored in dword_15E38)
    static int s_token = 0;
    static dispatch_once_t s_once = 0;
    dispatch_once(&s_once, ^{
        notify_register_check(kBINFlashNotifyChannel, &s_token);
    });
    if (!s_token) return;

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

    notify_set_state(s_token, s);
}

// --- sub_7E78 (0x7E78) ---
// Merge new values into prefs, write all plist paths, encode state, post notify.
void BINFlashSavePrefs(NSDictionary *newValues) {
    // Load current prefs and merge
    NSMutableDictionary *merged = [BINFlashLoadPrefs() mutableCopy];
    if ([newValues isKindOfClass:[NSDictionary class]])
        [merged addEntriesFromDictionary:newValues];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in _plistPaths()) {
        // Ensure parent directory exists
        NSString *dir = [path stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        // Write plist atomically
        [merged writeToFile:path atomically:YES];

        // Set file permissions to 0644 (decimal 420)
        [fm setAttributes:@{NSFilePosixPermissions: @(420)} ofItemAtPath:path error:nil];
    }

    // Encode state into Darwin notify channel
    _packAndSetState(merged);

    // Wake all listeners
    notify_post(kBINFlashNotifyChannel);
}
