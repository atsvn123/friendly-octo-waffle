// NetHelperHooks.h
// Reconstructed from:
//   sub_420C (0x420C) — +[NSURL URLWithString:] hook
//   sub_44AC (0x44AC) — iCdfsIdfdEdfsNdfdftqWer::url getter hook
//   sub_46D8 (0x46D8) — iCdfsIdfdEdfsNdfdftqWer::setUrl: setter hook
//   sub_47F4 (0x47F4) — GCD timer event handler (anti-Frida check)

#import <Foundation/Foundation.h>

// Domain substitution constants
#define kNetHelperFromDomain  "apps.bkatm.com"
#define kNetHelperToDomain    "kkameugojm.catto.lol"

// Obfuscated class name for the network request class (from vcamera.dylib or the main app)
// Has "url" property (getter + setter).
#define kNetHelperTargetClass "iCdfsIdfdEdfsNdfdftqWer"

// Guard flags (defined in Tweak.x)
extern BOOL g_fridaDetected;   // byte_C068
extern BOOL g_guardFlag;       // byte_C06C
extern int  g_urlCallCount;    // dword_C070

// Called from Tweak.x constructor to install all 3 MSHookMessageEx hooks.
void NetHelperInstallHooks(void);

// Called from the 5-second GCD timer event handler block.
// sub_47F4: if Frida is detected (via flags) → exit(0), else increment counter.
void NetHelperTimerTick(void);
