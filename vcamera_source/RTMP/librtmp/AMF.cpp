// AMF.cpp
// AMF0 encoding / decoding implementation.

#include "AMF.h"
#include <string.h>
#include <stdexcept>
#include <algorithm>

namespace librtmp {

// ─── AMFValue ────────────────────────────────────────────────────────────────

bool AMFValue::hasKey(const std::string &k) const {
    for (size_t i = 0; i < object.size(); i++)
        if (object[i].first == k) return true;
    return false;
}

const AMFValue &AMFValue::operator[](const std::string &k) const {
    for (size_t i = 0; i < object.size(); i++)
        if (object[i].first == k) return object[i].second;
    throw std::out_of_range("AMFValue: key not found: " + k);
}

AMFValue &AMFValue::operator[](const std::string &k) {
    for (size_t i = 0; i < object.size(); i++)
        if (object[i].first == k) return object[i].second;
    object.push_back(std::make_pair(k, AMFValue()));
    return object.back().second;
}

void AMFValue::set(const std::string &k, const AMFValue &v) {
    for (size_t i = 0; i < object.size(); i++) {
        if (object[i].first == k) { object[i].second = v; return; }
    }
    object.push_back(std::make_pair(k, v));
}

// ─── AMFDecoder ──────────────────────────────────────────────────────────────

AMFDecoder::AMFDecoder(const uint8_t *data, size_t len)
    : _data(data), _len(len), _pos(0) {}

bool AMFDecoder::empty() const { return _pos >= _len; }

uint8_t AMFDecoder::readU8() {
    if (_pos >= _len) throw std::runtime_error("AMF: unexpected end");
    return _data[_pos++];
}

uint16_t AMFDecoder::readU16BE() {
    uint8_t b0 = readU8(), b1 = readU8();
    return (uint16_t)((b0 << 8) | b1);
}

uint32_t AMFDecoder::readU32BE() {
    uint8_t b0 = readU8(), b1 = readU8(), b2 = readU8(), b3 = readU8();
    return ((uint32_t)b0 << 24) | ((uint32_t)b1 << 16) | ((uint32_t)b2 << 8) | b3;
}

double AMFDecoder::readDouble() {
    // IEEE 754 double, big-endian
    uint8_t bytes[8];
    for (int i = 0; i < 8; i++) bytes[i] = readU8();
    // Reverse to native (little-endian ARM)
    uint8_t rev[8];
    for (int i = 0; i < 8; i++) rev[i] = bytes[7 - i];
    double d;
    memcpy(&d, rev, 8);
    return d;
}

std::string AMFDecoder::readShortString() {
    uint16_t len = readU16BE();
    if (_pos + len > _len) throw std::runtime_error("AMF: string overflow");
    std::string s((const char *)(_data + _pos), len);
    _pos += len;
    return s;
}

AMFValue AMFDecoder::readObject() {
    AMFValue v;
    v.type = AMF0_OBJECT;
    while (true) {
        // Key length
        if (_pos + 2 > _len) throw std::runtime_error("AMF: object truncated");
        uint16_t klen = readU16BE();
        if (klen == 0) {
            // Object end marker follows: 0x09
            uint8_t tag = readU8();
            if (tag != AMF0_OBJECT_END) throw std::runtime_error("AMF: expected object end");
            break;
        }
        if (_pos + klen > _len) throw std::runtime_error("AMF: key overflow");
        std::string key((const char *)(_data + _pos), klen);
        _pos += klen;
        AMFValue val = readValue();
        v.object.push_back(std::make_pair(key, val));
    }
    return v;
}

AMFValue AMFDecoder::readECMAArray() {
    AMFValue v;
    v.type = AMF0_ECMA_ARRAY;
    readU32BE(); // associative count (informational only)
    // Same wire format as object: key-value pairs + terminator
    while (true) {
        if (_pos + 2 > _len) break;
        uint16_t klen = readU16BE();
        if (klen == 0) {
            if (_pos < _len) readU8(); // consume 0x09 object-end
            break;
        }
        if (_pos + klen > _len) break;
        std::string key((const char *)(_data + _pos), klen);
        _pos += klen;
        AMFValue val = readValue();
        v.object.push_back(std::make_pair(key, val));
    }
    return v;
}

AMFValue AMFDecoder::readValue() {
    uint8_t tag = readU8();
    AMFValue v;
    switch (tag) {
    case AMF0_NUMBER:
        v.type   = AMF0_NUMBER;
        v.number = readDouble();
        break;
    case AMF0_BOOLEAN:
        v.type    = AMF0_BOOLEAN;
        v.boolean = (readU8() != 0);
        break;
    case AMF0_STRING:
        v.type = AMF0_STRING;
        v.str  = readShortString();
        break;
    case AMF0_OBJECT:
        v = readObject();
        break;
    case AMF0_NULL:
    case AMF0_UNDEFINED:
        v.type = AMF0_NULL;
        break;
    case AMF0_ECMA_ARRAY:
        v = readECMAArray();
        break;
    case AMF0_STRICT_ARRAY: {
        v.type = AMF0_STRICT_ARRAY;
        uint32_t count = readU32BE();
        for (uint32_t i = 0; i < count; i++)
            v.array.push_back(readValue());
        break;
    }
    default:
        // Unknown type — skip and return null
        v.type = AMF0_NULL;
        break;
    }
    return v;
}

AMFValue AMFDecoder::decode()    { return readValue(); }
double   AMFDecoder::readNumber(){ return decode().number; }
std::string AMFDecoder::readString() { return decode().str; }

// ─── AMFEncoder ──────────────────────────────────────────────────────────────

void AMFEncoder::writeU8(uint8_t v)   { _buf.push_back(v); }

void AMFEncoder::writeU16BE(uint16_t v) {
    _buf.push_back((v >> 8) & 0xFF);
    _buf.push_back(v & 0xFF);
}

void AMFEncoder::writeU32BE(uint32_t v) {
    _buf.push_back((v >> 24) & 0xFF);
    _buf.push_back((v >> 16) & 0xFF);
    _buf.push_back((v >>  8) & 0xFF);
    _buf.push_back(v & 0xFF);
}

void AMFEncoder::writeDouble(double d) {
    uint8_t bytes[8];
    memcpy(bytes, &d, 8);
    // Little-endian → big-endian
    for (int i = 7; i >= 0; i--) _buf.push_back(bytes[i]);
}

void AMFEncoder::writeShortString(const std::string &s) {
    writeU16BE((uint16_t)s.size());
    for (size_t i = 0; i < s.size(); i++) _buf.push_back((uint8_t)s[i]);
}

void AMFEncoder::encodeNull()            { writeU8(AMF0_NULL); }
void AMFEncoder::encodeNumber(double n)  { writeU8(AMF0_NUMBER); writeDouble(n); }
void AMFEncoder::encodeBoolean(bool b)   { writeU8(AMF0_BOOLEAN); writeU8(b ? 1 : 0); }
void AMFEncoder::encodeString(const std::string &s) {
    writeU8(AMF0_STRING);
    writeShortString(s);
}
void AMFEncoder::beginObject()           { writeU8(AMF0_OBJECT); }
void AMFEncoder::encodeKey(const std::string &k) { writeShortString(k); }
void AMFEncoder::endObject() {
    writeU16BE(0);        // empty key
    writeU8(AMF0_OBJECT_END);
}
void AMFEncoder::encodeECMAArray(uint32_t size) {
    writeU8(AMF0_ECMA_ARRAY);
    writeU32BE(size);
}

void AMFEncoder::encodeValue(const AMFValue &v) {
    switch (v.type) {
    case AMF0_NUMBER:   encodeNumber(v.number); break;
    case AMF0_BOOLEAN:  encodeBoolean(v.boolean); break;
    case AMF0_STRING:   encodeString(v.str); break;
    case AMF0_NULL:     encodeNull(); break;
    case AMF0_OBJECT:
        beginObject();
        for (size_t i = 0; i < v.object.size(); i++) {
            encodeKey(v.object[i].first);
            encodeValue(v.object[i].second);
        }
        endObject();
        break;
    default:
        encodeNull();
        break;
    }
}

} // namespace librtmp
