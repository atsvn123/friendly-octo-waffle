// IPCProtocol.h
// IPC message format for the VCamBridge localhost channel (port 22222).
// Reconstructed from VCamBridge::run (0x88404) which builds login packets,
// and the ReadStreamClientCallBack (0x872B0) which processes inbound data.
//
// Wire format — each message begins with an 8-byte header:
//   byte 0: payload length (low byte)
//   bytes 1-3: reserved (0)
//   byte 4: message type (1 = string field)
//   bytes 5-7: reserved (0)
// Followed by the payload bytes.
//
// A login exchange consists of two such packets: username then password.
// Command packets use the same header; byte 4 encodes the command type.

#pragma once
#import <Foundation/Foundation.h>

// Message type codes (byte 4 of header)
typedef NS_ENUM(uint8_t, VCamIPCType) {
    VCamIPCTypeString    = 0x01,  // UTF-8 string field (username / password)
    VCamIPCTypeCommand   = 0x02,  // command (setLive / setBundleID / setResolution)
    VCamIPCTypeResponse  = 0x03,  // server → client response
};

// Command sub-codes (payload byte 0 when type == VCamIPCTypeCommand)
typedef NS_ENUM(uint8_t, VCamIPCCommand) {
    VCamIPCCmdSetLive        = 0x01,  // payload[1] = BOOL live
    VCamIPCCmdSetBundleID    = 0x02,  // payload[1..] = UTF-8 bundle ID
    VCamIPCCmdSetResolution  = 0x03,  // payload[1..8] = uint32 width + uint32 height
    VCamIPCCmdLoginOK        = 0x10,  // server → client: login accepted
    VCamIPCCmdLoginFail      = 0x11,  // server → client: login rejected
};

#pragma pack(push,1)
typedef struct {
    uint8_t  payloadLength;  // low byte of length (packets ≤ 255 bytes)
    uint8_t  reserved0[3];
    uint8_t  type;           // VCamIPCType
    uint8_t  reserved1[3];
} VCamIPCHeader;
#pragma pack(pop)

// Build a VCamIPCTypeString packet (used by VCamBridge::run for username/password)
static inline NSData *VCamIPCMakeStringPacket(NSString *str) {
    const char *utf8 = [str UTF8String];
    NSUInteger uLen  = utf8 ? strlen(utf8) : 0;
    NSMutableData *d = [NSMutableData dataWithCapacity:8 + uLen];
    VCamIPCHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.payloadLength = (uint8_t)(uLen & 0xFF);
    hdr.type          = VCamIPCTypeString;
    [d appendBytes:&hdr length:sizeof(hdr)];
    if (uLen > 0) [d appendBytes:utf8 length:uLen];
    return d;
}
