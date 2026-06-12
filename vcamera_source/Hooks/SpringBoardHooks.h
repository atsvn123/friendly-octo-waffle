// SpringBoardHooks.h
// MSHookMessageEx hooks installed in the SpringBoard process by vcamera.dylib.
// Tracks device lock/unlock state and screen orientation for the VCam UI overlay.

#pragma once
#import <Foundation/Foundation.h>

void installSpringBoardHooks(void);
