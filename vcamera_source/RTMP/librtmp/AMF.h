// AMF.h
// AMF0 encoding / decoding for the librtmp C++ namespace.
// Reconstructed from RTMPServerSession::HandleAMF (0xA0B44) which reads and
// writes AMF0 connect/createStream/publish/onMetaData messages.

#pragma once
#include <stdint.h>
#include <string>
#include <vector>
#include <stdexcept>

namespace librtmp {

// ─── AMF0 type tags ─────────────────────────────────────────────────────────
enum {
    AMF0_NUMBER       = 0x00,
    AMF0_BOOLEAN      = 0x01,
    AMF0_STRING       = 0x02,
    AMF0_OBJECT       = 0x03,
    AMF0_NULL         = 0x05,
    AMF0_UNDEFINED    = 0x06,
    AMF0_ECMA_ARRAY   = 0x08,
    AMF0_OBJECT_END   = 0x09,
    AMF0_STRICT_ARRAY = 0x0A,
};

// ─── AMFValue variant ────────────────────────────────────────────────────────
struct AMFValue {
    int type;           // AMF0_* constant

    // Payload (only one is valid depending on type)
    double      number;
    bool        boolean;
    std::string str;

    // Object / ECMA array: ordered key-value pairs
    std::vector< std::pair<std::string, AMFValue> > object;

    // Strict array: ordered values
    std::vector<AMFValue> array;

    AMFValue()                : type(AMF0_NULL),   number(0), boolean(false) {}
    explicit AMFValue(double n): type(AMF0_NUMBER), number(n), boolean(false) {}
    explicit AMFValue(bool   b): type(AMF0_BOOLEAN),number(0), boolean(b)    {}
    explicit AMFValue(const std::string &s): type(AMF0_STRING), number(0), boolean(false), str(s) {}
    explicit AMFValue(const char *s)       : type(AMF0_STRING), number(0), boolean(false), str(s) {}

    // Named-field accessors for object type
    bool hasKey(const std::string &k) const;
    const AMFValue &operator[](const std::string &k) const;
    AMFValue &operator[](const std::string &k);
    void set(const std::string &k, const AMFValue &v);
};

// ─── Decoder ─────────────────────────────────────────────────────────────────
// Reads a sequence of top-level AMF0 values from a byte buffer.
class AMFDecoder {
public:
    AMFDecoder(const uint8_t *data, size_t len);

    bool      empty() const;
    AMFValue  decode();       // decode next value
    double    readNumber();   // shorthand for next-value-as-number
    std::string readString(); // shorthand for next-value-as-string

private:
    const uint8_t *_data;
    size_t         _len;
    size_t         _pos;

    uint8_t  readU8();
    uint16_t readU16BE();
    uint32_t readU32BE();
    double   readDouble();
    std::string readShortString();
    AMFValue readObject();
    AMFValue readECMAArray();
    AMFValue readValue();
};

// ─── Encoder ─────────────────────────────────────────────────────────────────
class AMFEncoder {
public:
    void encodeNull();
    void encodeNumber(double n);
    void encodeBoolean(bool b);
    void encodeString(const std::string &s);
    void beginObject();
    void encodeKey(const std::string &k);
    void endObject();
    void encodeECMAArray(uint32_t size); // writes ECMA array header
    void encodeValue(const AMFValue &v);

    const std::vector<uint8_t> &buf() const { return _buf; }
    std::vector<uint8_t> take()             { return std::move(_buf); }

private:
    std::vector<uint8_t> _buf;

    void writeU8(uint8_t v);
    void writeU16BE(uint16_t v);
    void writeU32BE(uint32_t v);
    void writeDouble(double v);
    void writeShortString(const std::string &s);
};

} // namespace librtmp
