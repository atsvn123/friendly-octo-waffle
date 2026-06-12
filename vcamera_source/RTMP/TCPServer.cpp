// TCPServer.cpp
// Listens on 127.0.0.1:<port> and accepts one connection at a time.
// The RTMP server (port 1935) processes one client sequentially — a new accept()
// only starts after the previous session's C++ objects are destroyed.

#include "TCPServer.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdexcept>
namespace libvcam {

TCPServer::TCPServer(uint16_t port) : _listenFd(-1), _destroyed(false) {
    _listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFd < 0) {
        char em[64]; snprintf(em, sizeof(em), "socket() failed errno=%d", errno);
        throw std::runtime_error(em);
    }

    int yes = 1;
    ::setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR,  &yes, (socklen_t)sizeof(yes));
    // IDA 0xA6DD8: second setsockopt with option 0x200 = SO_REUSEPORT (macOS/iOS)
    ::setsockopt(_listenFd, SOL_SOCKET, SO_REUSEPORT,  &yes, (socklen_t)sizeof(yes));

    struct sockaddr_in addr;
    ::memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (::bind(_listenFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int e = errno;
        ::close(_listenFd);
        char em[64]; snprintf(em, sizeof(em), "bind(%d) failed errno=%d(%s)", (int)port, e, strerror(e));
        throw std::runtime_error(em);
    }

    // IDA 0xA6E10: listen backlog = 128
    if (::listen(_listenFd, 128) < 0) {
        int e = errno;
        ::close(_listenFd);
        char em[64]; snprintf(em, sizeof(em), "listen(%d) failed errno=%d(%s)", (int)port, e, strerror(e));
        throw std::runtime_error(em);
    }
}

TCPServer::~TCPServer() {
    destroy();
}

int TCPServer::accept() {
    struct sockaddr_in clientAddr;
    socklen_t addrLen = sizeof(clientAddr);
    ::memset(&clientAddr, 0, sizeof(clientAddr));

    int clientFd = ::accept(_listenFd, (struct sockaddr *)&clientAddr, &addrLen);
    if (clientFd < 0)
        throw std::runtime_error("TCPServer: accept() failed");
    return clientFd;
}

void TCPServer::destroy() {
    if (!_destroyed) {
        _destroyed = true;
        if (_listenFd >= 0) {
            ::shutdown(_listenFd, SHUT_RDWR);
            ::close(_listenFd);
            _listenFd = -1;
        }
    }
}

} // namespace libvcam
