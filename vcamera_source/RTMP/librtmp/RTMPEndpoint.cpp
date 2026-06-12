// RTMPEndpoint.cpp
// RTMP chunk-layer implementation.
// Protocol reference: Adobe RTMP specification rev 2012-12-21

#include "RTMPEndpoint.h"
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <stdexcept>

namespace librtmp {

static const uint32_t DEFAULT_IN_CHUNK_SIZE  = 128;
static const uint32_t DEFAULT_OUT_CHUNK_SIZE = 4096;
static const uint32_t HANDSHAKE_SIZE         = 1536;

RTMPEndpoint::RTMPEndpoint(libvcam::DataLayer *layer)
    : _layer(layer),
      _inChunkSize(DEFAULT_IN_CHUNK_SIZE),
      _outChunkSize(DEFAULT_OUT_CHUNK_SIZE) {}

RTMPEndpoint::~RTMPEndpoint() {}

// ─── Handshake ────────────────────────────────────────────────────────────────
// Server-side: recv C0+C1, send S0+S1+S2, recv C2
void RTMPEndpoint::doHandshake() {
    // --- C0 ---
    uint8_t c0 = _layer->readU8();
    if (c0 != 0x03)
        throw std::runtime_error("RTMP: unsupported version");

    // --- C1 ---
    uint8_t c1[HANDSHAKE_SIZE];
    _layer->readExact(c1, HANDSHAKE_SIZE);

    // --- S0 ---
    _layer->writeU8(0x03);

    // --- S1 --- (timestamp + zeros + random)
    uint8_t s1[HANDSHAKE_SIZE];
    memset(s1, 0, HANDSHAKE_SIZE);
    uint32_t now = (uint32_t)time(NULL);
    s1[0] = (now >> 24) & 0xFF;
    s1[1] = (now >> 16) & 0xFF;
    s1[2] = (now >>  8) & 0xFF;
    s1[3] = now & 0xFF;
    // bytes 4-7 = zeros (server version)
    // bytes 8..HANDSHAKE_SIZE-1 = pseudo-random
    for (int i = 8; i < (int)HANDSHAKE_SIZE; i++)
        s1[i] = (uint8_t)(i & 0xFF);

    _layer->writeExact(s1, HANDSHAKE_SIZE);

    // --- S2 --- (echo of C1: C1's time, our time, C1's random body)
    uint8_t s2[HANDSHAKE_SIZE];
    memcpy(s2, c1, 4);        // client time
    s2[4] = (now >> 24) & 0xFF; // our time
    s2[5] = (now >> 16) & 0xFF;
    s2[6] = (now >>  8) & 0xFF;
    s2[7] = now & 0xFF;
    memcpy(s2 + 8, c1 + 8, HANDSHAKE_SIZE - 8);
    _layer->writeExact(s2, HANDSHAKE_SIZE);

    // --- C2 --- (echo of S1 — we validate loosely: just consume)
    uint8_t c2[HANDSHAKE_SIZE];
    _layer->readExact(c2, HANDSHAKE_SIZE);
    (void)c2;
}

// ─── Chunk reading ────────────────────────────────────────────────────────────

// Read basic header byte(s). Returns chunk stream ID; sets *fmtOut = fmt field.
int RTMPEndpoint::readBasicHeader(uint8_t *fmtOut) {
    uint8_t b = _layer->readU8();
    *fmtOut   = (b >> 6) & 0x03;
    int csId  = b & 0x3F;

    if (csId == 0) {
        // 2-byte basic header
        csId = _layer->readU8() + 64;
    } else if (csId == 1) {
        // 3-byte basic header (big-endian 16-bit)
        uint8_t b1 = _layer->readU8();
        uint8_t b2 = _layer->readU8();
        csId = ((int)b2 << 8 | b1) + 64;
    }
    return csId;
}

uint32_t RTMPEndpoint::read3BytesBE() {
    uint8_t b[3];
    _layer->readExact(b, 3);
    return ((uint32_t)b[0] << 16) | ((uint32_t)b[1] << 8) | b[2];
}

// 4-byte LITTLE-endian (stream ID field in type-0 headers)
uint32_t RTMPEndpoint::read4BytesLE() {
    uint8_t b[4];
    _layer->readExact(b, 4);
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

void RTMPEndpoint::readChunkHeader(int csId, uint8_t fmt, ChunkStreamState &cs) {
    if (fmt == 0) {
        // Full header: timestamp(3) + length(3) + type(1) + stream_id(4 LE)
        uint32_t ts  = read3BytesBE();
        cs.length    = read3BytesBE();
        cs.type      = _layer->readU8();
        cs.streamId  = read4BytesLE();
        if (ts == 0xFFFFFF) {
            // Extended timestamp
            uint8_t ext[4]; _layer->readExact(ext, 4);
            ts = ((uint32_t)ext[0]<<24)|((uint32_t)ext[1]<<16)|((uint32_t)ext[2]<<8)|ext[3];
        }
        cs.timestamp = ts;
        cs.delta     = 0;
        cs.partialPayload.clear();
        cs.bytesReceived = 0;

    } else if (fmt == 1) {
        // delta(3) + length(3) + type(1)  — stream_id same as before
        uint32_t d  = read3BytesBE();
        cs.length   = read3BytesBE();
        cs.type     = _layer->readU8();
        if (d == 0xFFFFFF) {
            uint8_t ext[4]; _layer->readExact(ext, 4);
            d = ((uint32_t)ext[0]<<24)|((uint32_t)ext[1]<<16)|((uint32_t)ext[2]<<8)|ext[3];
        }
        cs.delta     = d;
        cs.timestamp += d;
        cs.partialPayload.clear();
        cs.bytesReceived = 0;

    } else if (fmt == 2) {
        // delta(3) only — length, type, stream_id same as before
        uint32_t d  = read3BytesBE();
        if (d == 0xFFFFFF) {
            uint8_t ext[4]; _layer->readExact(ext, 4);
            d = ((uint32_t)ext[0]<<24)|((uint32_t)ext[1]<<16)|((uint32_t)ext[2]<<8)|ext[3];
        }
        cs.delta     = d;
        cs.timestamp += d;
        cs.partialPayload.clear();
        cs.bytesReceived = 0;

    } else {
        // fmt == 3: no header — same chunk stream state, just continue accumulating
        if (cs.bytesReceived == 0 && cs.length > 0) {
            // New message using all previous header fields (common for type-3 continuation)
        }
    }
}

RTMPMessage RTMPEndpoint::readMessage() {
    for (;;) {
        uint8_t fmt;
        int csId = readBasicHeader(&fmt);

        ChunkStreamState &cs = _csState[csId];
        readChunkHeader(csId, fmt, cs);

        // How many bytes to read for this chunk?
        uint32_t remaining = cs.length - cs.bytesReceived;
        uint32_t toRead    = (remaining < _inChunkSize) ? remaining : _inChunkSize;

        size_t oldSize = cs.partialPayload.size();
        cs.partialPayload.resize(oldSize + toRead);
        _layer->readExact(&cs.partialPayload[oldSize], toRead);
        cs.bytesReceived += toRead;

        if (cs.bytesReceived >= cs.length) {
            // Message complete — assemble and return
            RTMPMessage msg;
            msg.type      = cs.type;
            msg.streamId  = cs.streamId;
            msg.timestamp = cs.timestamp;
            msg.payload   = cs.partialPayload;

            // Reset accumulator for next message on this CS
            cs.partialPayload.clear();
            cs.bytesReceived = 0;

            // Handle Set Chunk Size inline (control — must update _inChunkSize)
            if (msg.type == RTMP_MSG_SET_CHUNK_SIZE && msg.payload.size() >= 4) {
                _inChunkSize = ((uint32_t)msg.payload[0] << 24) |
                               ((uint32_t)msg.payload[1] << 16) |
                               ((uint32_t)msg.payload[2] <<  8) |
                                msg.payload[3];
                _inChunkSize &= 0x7FFFFFFF; // MSB must be 0
                continue; // transparent — don't return to caller
            }

            return msg;
        }
        // Message not yet complete — loop and read next chunk
    }
}

// ─── Chunk writing ────────────────────────────────────────────────────────────

void RTMPEndpoint::sendMessage(uint8_t type, uint32_t streamId, uint32_t timestamp,
                                const std::vector<uint8_t> &payload, int csId)
{
    const uint8_t *p   = payload.data();
    size_t          rem = payload.size();
    bool            first = true;

    while (first || rem > 0) {
        size_t toWrite = (rem < _outChunkSize) ? rem : _outChunkSize;

        if (first) {
            // fmt=0 (full header) for the first chunk
            uint8_t hdr[12];
            hdr[0]  = (uint8_t)(((0 & 0x03) << 6) | (csId & 0x3F));
            hdr[1]  = (timestamp >> 16) & 0xFF;
            hdr[2]  = (timestamp >>  8) & 0xFF;
            hdr[3]  = timestamp & 0xFF;
            hdr[4]  = (rem >> 16) & 0xFF;
            hdr[5]  = (rem >>  8) & 0xFF;
            hdr[6]  = rem & 0xFF;
            hdr[7]  = type;
            hdr[8]  = (streamId >>  0) & 0xFF; // LE
            hdr[9]  = (streamId >>  8) & 0xFF;
            hdr[10] = (streamId >> 16) & 0xFF;
            hdr[11] = (streamId >> 24) & 0xFF;
            _layer->writeExact(hdr, 12);
            first = false;
        } else {
            // fmt=3 (no header) for continuation chunks
            uint8_t b = (uint8_t)(((3 & 0x03) << 6) | (csId & 0x3F));
            _layer->writeU8(b);
        }

        _layer->writeExact(p, toWrite);
        p   += toWrite;
        rem -= toWrite;
    }
}

void RTMPEndpoint::sendControl(uint8_t type, const std::vector<uint8_t> &payload) {
    sendMessage(type, 0, 0, payload, 2);
}

} // namespace librtmp
