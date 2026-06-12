// VCamNetworkRequest.h
// Reconstructed from iCdfsIdfdEdfsNdfdftqWer
// HTTP login client for kkameugojm.catto.lol backend
// NetHelper.dylib hooks -[iCdfsIdfdEdfsNdfdftqWer setUrl:] to enforce this domain

#import <Foundation/Foundation.h>

// Callback: success=YES on code 0; success=NO with message on error
typedef void (^VCamNetworkCallback)(BOOL success, NSString *message);

// IMPORTANT: Class MUST be named exactly iCdfsIdfdEdfsNdfdftqWer for NetHelper hooks
@interface iCdfsIdfdEdfsNdfdftqWer : NSObject

@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *token;  // set from JSON response on login success

+ (instancetype)sharedInstance;  // ivar at +16, used by parse: code 1000 token check

- (void)login:(NSString *)username
     password:(NSString *)password
     callback:(VCamNetworkCallback)callback;

@end
