// VCamTLSClient.h
// ObjC wrapper for mbedTLS (PolarSSL successor) TLS client.
// Reconstructed from PolarSSL strings in vcamera.dylib:
//   ssl_cli.c, ssl_srv.c, ssl_tls.c at /Volumes/space/objcwork/vcam/polarssl/library/

#import <Foundation/Foundation.h>

@protocol VCamTLSClientDelegate <NSObject>
- (void)tlsClient:(id)client didReceiveData:(NSData *)data;
- (void)tlsClientDidDisconnect:(id)client;
- (void)tlsClient:(id)client didFailWithError:(NSError *)error;
@end

@interface VCamTLSClient : NSObject

@property (nonatomic, assign) id<VCamTLSClientDelegate> delegate;
@property (nonatomic, readonly) BOOL isConnected;

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port;
- (BOOL)connect;
- (void)disconnect;
- (BOOL)sendData:(NSData *)data;
- (NSData *)readData:(NSUInteger)length;

@end
