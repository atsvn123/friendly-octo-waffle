// DataLayer.cpp

#include "DataLayer.h"
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdexcept>

namespace libvcam {

DataLayer::DataLayer(int fd) : _fd(fd), _closed(false) {}

DataLayer::~DataLayer() {
    close();
}

void DataLayer::readExact(void *buf, size_t len) {
    uint8_t *p = reinterpret_cast<uint8_t *>(buf);
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t n = ::recv(_fd, p, remaining, 0);
        if (n == 0)
            throw std::runtime_error("DataLayer: connection closed by peer");
        if (n < 0) {
            if (errno == EINTR) continue;
            throw std::runtime_error("DataLayer: recv() error");
        }
        p += n;
        remaining -= static_cast<size_t>(n);
    }
}

void DataLayer::writeExact(const void *buf, size_t len) {
    const uint8_t *p = reinterpret_cast<const uint8_t *>(buf);
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t n = ::send(_fd, p, remaining, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            throw std::runtime_error("DataLayer: send() error");
        }
        p += n;
        remaining -= static_cast<size_t>(n);
    }
}

uint8_t DataLayer::readU8() {
    uint8_t v = 0;
    readExact(&v, 1);
    return v;
}

void DataLayer::writeU8(uint8_t v) {
    writeExact(&v, 1);
}

void DataLayer::close() {
    if (!_closed) {
        _closed = true;
        if (_fd >= 0) {
            ::shutdown(_fd, SHUT_RDWR);
            ::close(_fd);
            _fd = -1;
        }
    }
}

} // namespace libvcam
