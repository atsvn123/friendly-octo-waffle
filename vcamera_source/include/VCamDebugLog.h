// VCamDebugLog.h — file-based debug logging for mediaserverd context.
// Tries multiple paths because the sandbox blocks some directories.
// Include in any .m / .mm / .cpp file that needs vcamLog().
#pragma once
#include <stdio.h>

static inline void vcamLog(const char *msg) {
    static const char *s_paths[] = {
        "/tmp/vcam_debug.log",
        "/var/tmp/vcam_debug.log",
        "/var/mobile/Media/vcam_debug.log",
        "/var/jb/tmp/vcam_debug.log",
        NULL
    };
    for (int i = 0; s_paths[i]; i++) {
        FILE *f = fopen(s_paths[i], "a");
        if (f) { fprintf(f, "%s\n", msg); fclose(f); return; }
    }
}

// Convenience macro — sprintf into a fixed buffer then call vcamLog.
#define VCAM_LOG(fmt, ...) do { \
    char _vcam_buf[256]; \
    snprintf(_vcam_buf, sizeof(_vcam_buf), fmt, ##__VA_ARGS__); \
    vcamLog(_vcam_buf); \
} while(0)
