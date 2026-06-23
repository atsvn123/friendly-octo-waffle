// MobileGestalt.h — private API stub
// Provides MGCopyAnswer for device identity queries.
// libMobileGestalt.dylib is at /usr/lib/libMobileGestalt.dylib on device.
// Link flag: -lMobileGestalt (in Makefile vcamera_LDFLAGS)

#pragma once
#import <CoreFoundation/CoreFoundation.h>

CF_EXTERN_C_BEGIN

// Returns a CFTypeRef (usually CFStringRef or CFNumberRef) for the given property key.
// Caller is responsible for CFRelease.
extern CFTypeRef MGCopyAnswer(CFStringRef property);

CF_EXTERN_C_END
