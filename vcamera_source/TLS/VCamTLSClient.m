// VCamTLSClient.m
// Wraps mbedTLS 2.28 (PolarSSL successor) for TLS auth to vcam backend.
// Original used PolarSSL 1.x — mbedTLS 2.x provides identical API surface.

#import "VCamTLSClient.h"
#import "mbedtls/ssl.h"
#import "mbedtls/entropy.h"
#import "mbedtls/ctr_drbg.h"
#import "mbedtls/net_sockets.h"
#import "mbedtls/error.h"
#import "mbedtls/x509_crt.h"

#import <Foundation/Foundation.h>
#import <string.h>

@implementation VCamTLSClient {
    NSString           *_host;
    uint16_t            _port;
    BOOL                _connected;

    mbedtls_ssl_context    _ssl;
    mbedtls_ssl_config     _conf;
    mbedtls_entropy_context  _entropy;
    mbedtls_ctr_drbg_context _ctrDrbg;
    mbedtls_net_context    _serverFd;
    mbedtls_x509_crt       _caCert;
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _connected = NO;

        mbedtls_ssl_init(&_ssl);
        mbedtls_ssl_config_init(&_conf);
        mbedtls_entropy_init(&_entropy);
        mbedtls_ctr_drbg_init(&_ctrDrbg);
        mbedtls_net_init(&_serverFd);
        mbedtls_x509_crt_init(&_caCert);
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
    mbedtls_ssl_free(&_ssl);
    mbedtls_ssl_config_free(&_conf);
    mbedtls_entropy_free(&_entropy);
    mbedtls_ctr_drbg_free(&_ctrDrbg);
    mbedtls_net_free(&_serverFd);
    mbedtls_x509_crt_free(&_caCert);
    [_host release];
    [super dealloc];
}

- (BOOL)isConnected {
    return _connected;
}

- (BOOL)connect {
    const char *pers = "vcam_tls";

    int ret = mbedtls_ctr_drbg_seed(&_ctrDrbg,
                                     mbedtls_entropy_func, &_entropy,
                                     (const unsigned char *)pers, strlen(pers));
    if (ret != 0) return NO;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", _port);

    ret = mbedtls_net_connect(&_serverFd,
                               [_host UTF8String],
                               portStr,
                               MBEDTLS_NET_PROTO_TCP);
    if (ret != 0) return NO;

    ret = mbedtls_ssl_config_defaults(&_conf,
                                       MBEDTLS_SSL_IS_CLIENT,
                                       MBEDTLS_SSL_TRANSPORT_STREAM,
                                       MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        mbedtls_net_free(&_serverFd);
        return NO;
    }

    // Skip certificate verification (original PolarSSL code used NONE mode for internal server)
    mbedtls_ssl_conf_authmode(&_conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_rng(&_conf, mbedtls_ctr_drbg_random, &_ctrDrbg);

    ret = mbedtls_ssl_setup(&_ssl, &_conf);
    if (ret != 0) {
        mbedtls_net_free(&_serverFd);
        return NO;
    }

    ret = mbedtls_ssl_set_hostname(&_ssl, [_host UTF8String]);
    if (ret != 0) {
        mbedtls_net_free(&_serverFd);
        return NO;
    }

    mbedtls_ssl_set_bio(&_ssl, &_serverFd,
                         mbedtls_net_send, mbedtls_net_recv, NULL);

    // TLS handshake
    while ((ret = mbedtls_ssl_handshake(&_ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            mbedtls_net_free(&_serverFd);
            return NO;
        }
    }

    _connected = YES;
    return YES;
}

- (void)disconnect {
    if (_connected) {
        mbedtls_ssl_close_notify(&_ssl);
        _connected = NO;
    }
    mbedtls_net_free(&_serverFd);
}

- (BOOL)sendData:(NSData *)data {
    if (!_connected || !data.length) return NO;

    const unsigned char *buf = (const unsigned char *)data.bytes;
    size_t remaining = data.length;

    while (remaining > 0) {
        int ret = mbedtls_ssl_write(&_ssl, buf, remaining);
        if (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_WANT_READ) continue;
        if (ret < 0) {
            _connected = NO;
            return NO;
        }
        buf += ret;
        remaining -= (size_t)ret;
    }
    return YES;
}

- (NSData *)readData:(NSUInteger)length {
    if (!_connected) return nil;

    NSMutableData *buffer = [NSMutableData dataWithLength:length];
    unsigned char *buf = (unsigned char *)buffer.mutableBytes;
    size_t totalRead = 0;

    while (totalRead < length) {
        int ret = mbedtls_ssl_read(&_ssl, buf + totalRead, length - totalRead);
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || ret == 0) {
            _connected = NO;
            break;
        }
        if (ret < 0) {
            _connected = NO;
            return nil;
        }
        totalRead += (size_t)ret;
    }

    if (totalRead < length)
        [buffer setLength:totalRead];

    return buffer;
}

@end
