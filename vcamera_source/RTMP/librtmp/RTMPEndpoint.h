// RTMPEndpoint.h
// RTMP chunk-layer: handshake + chunk read/write.
// Reconstructed from librtmp::RTMPEndpoint referenced at 0xA2BB8 (handleRTMP).
//
// Responsibilities:
//   - Server-side RTMP handshake (C0/C1/S0/S1/S2/C2)
//   - Read chunk headers and reassemble multi-chunk messages
//   - Write messages as RTMP chunks

#pragma once
#include "../DataLayer.h"
#include "RTMPTypes.h"
#include <map>

namespace librtmp {

// Per-chunk-stream state (for chunk header compression)
struct ChunkStreamState {
    uint32_t timestamp;   // last absolute timestamp
    uint32_t delta;       // last timestamp delta
    uint32_t length;      // last message length
    uint8_t  type;        // last message type
    uint32_t streamId;    // last stream id
    std::vector<uint8_t> partialPayload; // accumulated payload bytes
    uint32_t bytesReceived;              // bytes of current message received

    ChunkStreamState()
        : timestamp(0), delta(0), length(0), type(0),
          streamId(0), bytesReceived(0) {}
};

class RTMPEndpoint {
public:
    explicit RTMPEndpoint(libvcam::DataLayer *layer);
    ~RTMPEndpoint();

    // Perform server-side handshake. Must be called before readMessage/sendMessage.
    void doHandshake();

    // Read one complete reassembled RTMP message. Blocks. Throws on error.
    RTMPMessage readMessage();

    // Send one message as RTMP chunks on chunk stream csId.
    void sendMessage(uint8_t type, uint32_t streamId, uint32_t timestamp,
                     const std::vector<uint8_t> &payload, int csId = 3);

    // Convenience: send on control stream (CSID=2)
    void sendControl(uint8_t type, const std::vector<uint8_t> &payload);

private:
    libvcam::DataLayer *_layer; // not owned

    uint32_t _inChunkSize;   // negotiated inbound chunk size (default 128)
    uint32_t _outChunkSize;  // our outbound chunk size (we use 4096)

    std::map<int, ChunkStreamState> _csState; // keyed by chunk stream ID

    // Chunk reader helpers
    int      readBasicHeader(uint8_t *fmtOut);
    void     readChunkHeader(int csId, uint8_t fmt, ChunkStreamState &cs);
    uint32_t read3BytesBE();
    uint32_t read4BytesLE();
};

} // namespace librtmp
