# NetHelper.dylib — Full Flow Document

**Binary:** NetHelper.dylib  
**Format:** ARM64 Mach-O dylib  
**IDA instance:** port 13340  
**Analyzed:** 2026-06-09  

---

## Section 1: Binary Overview

| Field | Value |
|---|---|
| Architecture | ARM64 |
| File size | 0xC170 bytes (~49 KB) |
| Total functions | 45 (5 substantive, rest are thunks/stubs) |
| Total strings | 57 |
| Hook mechanism | `MSHookMessageEx` (ObjC methods) |
| Symbol lookup | `dlsym` (for Frida detection) |
| IPC | None (no Darwin notify, no plist) |
| Obfuscated class | `iCdfsIdfdEdfsNdfdftqWer` — network request class |

---

## Section 2: Purpose

NetHelper.dylib is a **URL redirect + anti-debug guard module**. It does two things:

1. **Redirects network requests**: When the app tries to reach `apps.bkatm.com` (the real/official backend), this module intercepts and silently replaces it with `bibq.net` (the VIP cracked server).

2. **Anti-Frida protection**: Detects Frida at startup and every 5 seconds. When Frida is present, the URL hooks are disabled (traffic goes to the real server, looking legitimate) and the process is killed after 5 seconds.

**Domain mapping:**
| Original | Replacement | Direction |
|---|---|---|
| `apps.bkatm.com` | `bibq.net` | Official → VIP backend |

---

## Section 3: Constructor — `sub_4000` (0x4000)

Called by `__init_offsets` on dylib load. Single constructor entry.

```
sub_4000 (0x4000)
│
├── 1. FRIDA DETECTION
│   ├── dlsym(RTLD_DEFAULT, "frida_agent_main")
│   └── dlsym(RTLD_DEFAULT, "gum_init_embedded")
│        ↓ either returns non-NULL
│   → Frida IS present:
│       byte_C068 = 1   ← disables URL replacement in all hooks
│       byte_C06C = 1   ← additional guard flag
│       (skip MSHookMessageEx calls entirely)
│
└── 2. Frida NOT present → install hooks + timer:
    │
    ├── GCD timer:
    │     queue name : "net.helper.guard"
    │     initial    : 5 seconds (5,000,000,000 ns)
    │     interval   : 5 seconds (0x12A05F200 ns)
    │     leeway     : 100ms (0x5F5E100 ns)
    │     handler    : stru_80F8 → sub_47F4
    │
    ├── MSHookMessageEx on NSURL metaclass:
    │     +[NSURL URLWithString:] → sub_420C (original: off_C050)
    │
    ├── MSHookMessageEx on iCdfsIdfdEdfsNdfdftqWer:
    │     url      → sub_44AC (original: off_C058)
    │     setUrl:  → sub_46D8 (original: off_C060)
    │
    └── Set guard flags to DISABLED state:
          byte_C068  = 0
          byte_C06C  = 0
          dword_C070 = 0   (URLWithString: call counter)
```

### Frida detection details

`dlsym(RTLD_DEFAULT, ...)` searches all currently loaded images. If Frida has been injected (via Frida gadget or `frida-ios-dump`), either `frida_agent_main` or `gum_init_embedded` will be resolvable. Both are entry points of the Frida runtime.

When detected at constructor time, the hooks are **never installed** — the app runs normally, routing traffic to the real server. This makes it difficult to detect the redirect by simply attaching Frida and sniffing traffic.

---

## Section 4: `+[NSURL URLWithString:]` Hook — `sub_420C` (0x420C)

Hooked on the **metaclass** of NSURL (class method). Every call to create an NSURL from a string goes through this.

```c
id sub_420C(id class, SEL cmd, NSString *urlString) {
    // Guard: if Frida detected OR either C06C flag set → pass through unmodified
    if ((byte_C068 & 1) || byte_C06C) {
        return off_C050(class, cmd, urlString);   // call original unchanged
    }

    // Increment call counter (wraps at 9999)
    dword_C070 = (dword_C070 < 9999) ? dword_C070 + 1 : 0;

    if (!urlString) {
        return off_C050(class, cmd, NULL);
    }

    NSString *from = @"apps.bkatm.com";   // only if !byte_C068
    NSString *to   = @"bibq.net";

    if (!from || !to) {
        return off_C050(class, cmd, urlString);   // safety fallback
    }

    // Case-insensitive search
    NSString *lowerURL  = [urlString lowercaseString];
    NSString *lowerFrom = [from lowercaseString];
    NSRange range = [lowerURL rangeOfString:lowerFrom];

    if (range.location != NSNotFound) {
        // Replace "apps.bkatm.com" with "bibq.net" in original string (options=1: case-insensitive)
        NSString *modified = [urlString stringByReplacingOccurrencesOfString:from
                                                                  withString:to
                                                                     options:1
                                                                       range:NSMakeRange(0, urlString.length)];
        return off_C050(class, cmd, modified);   // call original with modified URL
    }

    // URL doesn't contain target — call original unchanged
    return off_C050(class, cmd, urlString);
}
```

**Key behavior:** Only replaces URLs that contain `apps.bkatm.com`. All other URLs pass through unmodified.

---

## Section 5: `url` Getter Hook — `sub_44AC` (0x44AC)

Hooked on `iCdfsIdfdEdfsNdfdftqWer::url` — intercepts the URL *after* the original getter returns it.

```c
id sub_44AC(id self, SEL cmd) {
    if (!off_C058) return nil;

    // Call original getter
    NSString *original = off_C058(self, cmd);   // returns URL string

    if ((byte_C068 & 1)) {
        // Frida guard: return original as-is
        return original;
    }

    if (!original) return nil;

    NSString *from = @"apps.bkatm.com";
    NSString *to   = @"bibq.net";

    if (!from || !to) return original;

    // Case-insensitive search
    NSString *lowerURL  = [original lowercaseString];
    NSString *lowerFrom = [from lowercaseString];
    NSRange range = [lowerURL rangeOfString:lowerFrom];

    if (range.location != NSNotFound) {
        // Replace and return modified URL
        return [original stringByReplacingOccurrencesOfString:from
                                                   withString:to
                                                      options:1
                                                        range:NSMakeRange(0, original.length)];
    }

    return original;  // unchanged
}
```

---

## Section 6: `setUrl:` Setter Hook — `sub_46D8` (0x46D8)

Hooked on `iCdfsIdfdEdfsNdfdftqWer::setUrl:` — intercepts the URL *as it is being set*.

```c
void sub_46D8(id self, SEL cmd, NSString *urlString) {
    if (!off_C060) return;

    if (byte_C068 == 1) {
        // Frida detected: call original with the provided string unchanged
        off_C060(self, cmd, urlString);
        return;
    }

    // UNCONDITIONAL redirect: regardless of urlString value,
    // always set URL to "bibq.net"
    NSString *replacement = @"bibq.net";
    if (replacement) {
        off_C060(self, cmd, replacement);
    } else {
        off_C060(self, cmd, urlString);  // fallback if allocation failed
    }
}
```

**Critical difference from other hooks:** This does NOT check if the URL contains "apps.bkatm.com". It replaces **any** URL being set on this class with "bibq.net" unconditionally. This means whenever the app creates an `iCdfsIdfdEdfsNdfdftqWer` instance and calls `setUrl:`, it will always connect to `bibq.net` — regardless of what URL was specified in the source code.

---

## Section 7: Anti-Frida Timer Handler — `sub_47F4` (0x47F4)

The event handler block for the 5-second GCD timer. Fires continuously every 5 seconds after startup.

```c
void sub_47F4(void) {
    // Re-check Frida presence
    if ((byte_C068 & 1) || byte_C06C) {
        // Frida found: hard kill the process immediately
        exit(0);
    }

    // No Frida: increment run counter
    dword_C074++;

    // After 1000 timer ticks (≈83 minutes): reset guard flags
    if (dword_C074 >= 1000) {
        byte_C068  = 0;
        byte_C06C  = 0;
        dword_C074 = 0;
    }
}
```

**Two behaviors:**
1. **Frida present** → `exit(0)`. Even if Frida was not present at startup (it was attached later), the 5-second polling catches it and terminates the app.
2. **Frida absent** → periodic counter. After 1000 × 5s = 83.3 minutes, guard flags are reset. This suggests the flags can be set by something external (possibly another module calling into NetHelper), and this reset ensures they don't remain set permanently.

---

## Section 8: Globals

| Address | Name | Type | Contents |
|---|---|---|---|
| `byte_C068` | frida_detected | BOOL (byte) | 1 = Frida present, URL hooks disabled |
| `byte_C06C` | guard_flag | BOOL (byte) | Secondary disable flag |
| `dword_C070` | url_call_counter | int | URLWithString: invocation count, wraps at 9999 |
| `dword_C074` | timer_tick_counter | int | Timer fires since last reset |
| `off_C050` | orig_URLWithString | IMP | Original +[NSURL URLWithString:] |
| `off_C058` | orig_url_getter | IMP | Original iCdfsIdfdEdfsNdfdftqWer::url |
| `off_C060` | orig_setUrl | IMP | Original iCdfsIdfdEdfsNdfdftqWer::setUrl: |
| `stru_80F8` | timer_block | Block | GCD event handler block for 5-second timer |

---

## Section 9: Complete Data Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         CAMERA APP PROCESS                                │
│                                                                           │
│  NetHelper.dylib loaded by MobileLoader                                   │
│       │                                                                   │
│  sub_4000 (constructor)                                                   │
│       │                                                                   │
│       ├── dlsym(RTLD_DEFAULT, "frida_agent_main")                         │
│       ├── dlsym(RTLD_DEFAULT, "gum_init_embedded")                        │
│       │                                                                   │
│       │ [Frida DETECTED]                                                  │
│       ├──────────────────────────────────────────────────────────────┐   │
│       │  byte_C068 = 1, byte_C06C = 1                                │   │
│       │  Skip all MSHookMessageEx calls                              │   │
│       │  → App routes to REAL server (apps.bkatm.com)                │   │
│       │  → Start timer → exit(0) after first 5s tick                 │   │
│       └──────────────────────────────────────────────────────────────┘   │
│                                                                           │
│       │ [Frida NOT detected]                                              │
│       ├── GCD timer: 5s initial, 5s interval → sub_47F4                  │
│       ├── MSHookMessageEx: +[NSURL URLWithString:] → sub_420C            │
│       ├── MSHookMessageEx: iCdfsIdfdEdfsNdfdftqWer::url → sub_44AC       │
│       ├── MSHookMessageEx: iCdfsIdfdEdfsNdfdftqWer::setUrl: → sub_46D8   │
│       └── byte_C068=0, byte_C06C=0, dword_C070=0                         │
│                                                                           │
│  ─── RUNTIME NETWORK REQUEST FLOW ─────────────────────────────────────  │
│                                                                           │
│  App code: [NSURL URLWithString:@"https://apps.bkatm.com/api/..."]       │
│       │ (hooked → sub_420C)                                               │
│       ▼                                                                   │
│  Contains "apps.bkatm.com"? YES                                           │
│       ▼                                                                   │
│  Replace → "https://bibq.net/api/..."                                     │
│       ▼                                                                   │
│  Call original +[NSURL URLWithString:] with modified URL                  │
│       ▼                                                                   │
│  Request goes to bibq.net (VIP backend)                                   │
│                                                                           │
│  App code: [requestObj setUrl:@"https://apps.bkatm.com/check"]           │
│       │ (hooked → sub_46D8)                                               │
│       ▼                                                                   │
│  ALWAYS replace with @"bibq.net" (unconditional)                         │
│       ▼                                                                   │
│  Call original setUrl: with "bibq.net"                                    │
│                                                                           │
│  ─── PERIODIC ANTI-FRIDA CHECK ────────────────────────────────────────  │
│                                                                           │
│  Every 5 seconds:                                                         │
│  sub_47F4:                                                                │
│       if (byte_C068 || byte_C06C) → exit(0)  ← kills app if Frida found │
│       else: dword_C074++; if ≥1000 → reset flags                         │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Section 10: Hook Summary Table

| Hook | Original | Hook fn | Behavior |
|---|---|---|---|
| `+[NSURL URLWithString:]` | `off_C050` | `sub_420C` | Replace `apps.bkatm.com` → `bibq.net` if present |
| `iCdfsIdfdEdfsNdfdftqWer::url` | `off_C058` | `sub_44AC` | Replace `apps.bkatm.com` → `bibq.net` in returned URL |
| `iCdfsIdfdEdfsNdfdftqWer::setUrl:` | `off_C060` | `sub_46D8` | **Always** set to `bibq.net` |

---

## Section 11: Anti-Debug Summary

| Trigger | Check | Action |
|---|---|---|
| Startup | `dlsym(RTLD_DEFAULT, "frida_agent_main")` | Disable hooks, start kill timer |
| Startup | `dlsym(RTLD_DEFAULT, "gum_init_embedded")` | Disable hooks, start kill timer |
| Every 5 seconds | Re-check `byte_C068 \| byte_C06C` | `exit(0)` if set |
| In URLWithString: hook | Check `byte_C068 \| byte_C06C` | Pass through unmodified |
| In url getter hook | Check `byte_C068` | Return original value |
| In setUrl: hook | Check `byte_C068` | Use original string |
