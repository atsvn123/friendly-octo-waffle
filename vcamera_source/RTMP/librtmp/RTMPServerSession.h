// RTMPServerSession.h
// RTMP application-layer session: handles AMF commands, returns decoded H.264 data.
// Reconstructed from RTMPServerSession::HandleAMF (0xA0B44) and GetRTMPMessage (0xA2BB8).
//
// The caller (RTMPServer::handleRTMP) calls GetRTMPMessage() in a loop.
// Protocol messages (connect, createStream, publish, onMetaData) are handled
// internally. Video messages (type=0x09) carrying AVC NAL units are returned
// to the caller with isVideo()==true.

#pragma once
#include "RTMPEndpoint.h"
#include "RTMPTypes.h"
#include "AMF.h"
#include <string>

namespace librtmp {

// Decoded H.264 data extracted from an RTMP video message
struct H264Frame {
    bool isSequenceHeader; // true → SPS+PPS record; false → NAL units
    bool isKeyframe;

    // For sequence header:
    std::vector<uint8_t> sps;  // raw SPS NAL (without AVCC length prefix)
    std::vector<uint8_t> pps;  // raw PPS NAL

    // For NAL units:
    // AVCC-formatted: [4-byte-BE-len][NALU][4-byte-BE-len][NALU]...
    // Passed directly to CMBlockBufferCreateWithMemoryBlock (kCFAllocatorNull, no copy).
    std::vector<uint8_t> nalu;

    uint32_t compositionTime; // CTS in ms
    uint32_t timestamp;
};

class RTMPServerSession {
public:
    explicit RTMPServerSession(RTMPEndpoint *endpoint);
    ~RTMPServerSession();

    // Process RTMP messages until a complete H.264 video frame is ready.
    // Protocol messages (AMF commands, ACK, etc.) are handled silently.
    // Returns the next video frame. Throws on connection error.
    H264Frame GetRTMPMessage();

private:
    RTMPEndpoint *_endpoint; // not owned
    uint32_t _streamId;      // allocated stream ID (createStream)
    bool     _publishing;    // set after publish command

    // Transaction ID for responses
    double _txId;

    void handleAMF(const RTMPMessage &msg);
    void handleVideo(const RTMPMessage &msg, H264Frame &outFrame, bool &gotFrame);
    void handleWindowAckSize(const RTMPMessage &msg);
    void handleUserControl(const RTMPMessage &msg);

    // Helpers to send AMF responses
    void sendConnectResult(double txId);
    void sendCreateStreamResult(double txId);
    void sendPublishStart();
    void sendWindowAckSize(uint32_t size);
    void sendSetPeerBandwidth(uint32_t size, uint8_t limitType);
    void sendUserControl(uint16_t eventType, uint32_t eventData);
    void sendSetChunkSize(uint32_t size);
    void sendAck(uint32_t seqNum);

    std::vector<uint8_t> buildAMF(const std::string &cmd, double txId,
                                   const AMFValue &obj1, const AMFValue &obj2);

    uint32_t _bytesReceived; // for ACK
};

} // namespace librtmp
