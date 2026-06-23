// DataLayer.h
// Buffered socket read/write abstraction used by RTMPEndpoint.
// Reconstructed from the C++ DataLayer class referenced at 0xA2BB8 (handleRTMP).

#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdexcept>

namespace libvcam {

class DataLayer {
public:
    explicit DataLayer(int fd);
    ~DataLayer();

    // Read exactly len bytes into buf. Throws std::runtime_error on EOF or error.
    void readExact(void *buf, size_t len);

    // Write exactly len bytes from buf. Throws on error.
    void writeExact(const void *buf, size_t len);

    // Convenience: read/write single byte
    uint8_t readU8();
    void    writeU8(uint8_t v);

    int  fd()     const { return _fd; }
    bool closed() const { return _closed; }
    void close();

private:
    int  _fd;
    bool _closed;
};

} // namespace libvcam
