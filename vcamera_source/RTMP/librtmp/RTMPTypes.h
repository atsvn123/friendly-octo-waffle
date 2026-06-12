// RTMPTypes.h
// Shared RTMP message type constants and RTMPMessage struct.

#pragma once
#include <stdint.h>
#include <vector>

namespace librtmp {

// ─── RTMP message type IDs ─────────────────────────────────────────────────
enum RTMPMessageType {
    RTMP_MSG_SET_CHUNK_SIZE         = 0x01,
    RTMP_MSG_ABORT                  = 0x02,
    RTMP_MSG_ACKNOWLEDGEMENT        = 0x03,
    RTMP_MSG_USER_CONTROL           = 0x04,
    RTMP_MSG_WINDOW_ACK_SIZE        = 0x05,
    RTMP_MSG_SET_PEER_BANDWIDTH     = 0x06,
    RTMP_MSG_AUDIO                  = 0x08,
    RTMP_MSG_VIDEO                  = 0x09,
    RTMP_MSG_DATA_AMF3              = 0x0F,
    RTMP_MSG_SHARED_OBJ_AMF3        = 0x10,
    RTMP_MSG_COMMAND_AMF3           = 0x11,
    RTMP_MSG_DATA_AMF0              = 0x12,
    RTMP_MSG_SHARED_OBJ_AMF0        = 0x13,
    RTMP_MSG_COMMAND_AMF0           = 0x14,
    RTMP_MSG_AGGREGATE              = 0x16,
};

// ─── User Control event types ─────────────────────────────────────────────
enum RTMPUserControlType {
    RTMP_UCM_STREAM_BEGIN         = 0,
    RTMP_UCM_STREAM_EOF           = 1,
    RTMP_UCM_STREAM_DRY           = 2,
    RTMP_UCM_SET_BUFFER_LENGTH    = 3,
    RTMP_UCM_STREAM_IS_RECORDED   = 4,
    RTMP_UCM_PING_REQUEST         = 6,
    RTMP_UCM_PING_RESPONSE        = 7,
};

// ─── Reassembled RTMP message (post-chunk-demux) ──────────────────────────
struct RTMPMessage {
    uint8_t  type;           // RTMPMessageType
    uint32_t streamId;       // message stream ID (0 = control)
    uint32_t timestamp;      // absolute timestamp (ms)
    std::vector<uint8_t> payload;

    bool isVideo()   const { return type == RTMP_MSG_VIDEO; }
    bool isAudio()   const { return type == RTMP_MSG_AUDIO; }
    bool isCommand() const { return type == RTMP_MSG_COMMAND_AMF0 || type == RTMP_MSG_COMMAND_AMF3; }
    bool isData()    const { return type == RTMP_MSG_DATA_AMF0   || type == RTMP_MSG_DATA_AMF3; }
};

} // namespace librtmp
