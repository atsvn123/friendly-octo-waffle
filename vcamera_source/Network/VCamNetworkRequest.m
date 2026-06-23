// VCamNetworkRequest.m
// Reconstructed from iCdfsIdfdEdfsNdfdftqWer (IDA 0x9ABC8)
//
// Login flow (IDA-verified):
//   1. Compute timestamp = floor(timeIntervalSince1970 * 1000) (epoch ms)
//   2. MD5-hash password → 32 lowercase hex chars (fWerckASqdKhdgSkdhIjddf)
//   3. Compute device hash = base64(SHA-256(SerialNumber || UDID)) (fAsdjytEfRgsjYfsgc)
//   4. Build percent-encoded body: username=X&password=MD5&hash=SHA256&timestamp=MS
//   5. POST to {self->_url}/user/login as raw UTF-8 (NO XOR, NO AES — IDA confirmed)
//   6. Parse JSON response {code:0, token:...} or {code:N, message:...}
//   7. Call callback with success/failure

#import "VCamNetworkRequest.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// MobileGestalt — loaded at runtime to avoid link-time dependency
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef, CFDictionaryRef);
static MGCopyAnswer_t s_MGCopyAnswer = NULL;

static void loadMobileGestalt(void) {
    if (s_MGCopyAnswer) return;
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (!handle) handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (handle) s_MGCopyAnswer = (MGCopyAnswer_t)dlsym(handle, "MGCopyAnswer");
}

static NSString *md5HexString(NSString *input) {
    const char *str = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(str, (CC_LONG)strlen(str), digest);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [NSString stringWithString:hex];
}

static NSString *deviceHash(void) {
    loadMobileGestalt();
    NSString *serial = @"";
    NSString *mge    = @"";
    if (s_MGCopyAnswer) {
        CFTypeRef s = s_MGCopyAnswer(CFSTR("SerialNumber"), NULL);
        CFTypeRef m = s_MGCopyAnswer(CFSTR("k5lVWbXuiZHLA17KGiVUAA"), NULL);
        if (s) { serial = [(NSString *)s autorelease]; }  // CF → ObjC, MRC autorelease
        if (m) { mge    = [(NSString *)m autorelease]; }
    }
    NSString *combined = [serial stringByAppendingString:mge];
    const char *str = [combined UTF8String];
    unsigned char sha[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(str, (CC_LONG)strlen(str), sha);
    NSData *shaData = [[NSData alloc] initWithBytes:sha length:CC_SHA256_DIGEST_LENGTH];
    NSString *b64 = [shaData base64EncodedStringWithOptions:0];
    [shaData release];
    return b64;
}

// ── iCdfsIdfdEdfsNdfdftqWer ───────────────────────────────────────────────────

@implementation iCdfsIdfdEdfsNdfdftqWer {
    NSString *_url;
    NSString *_token;  // stored at ivar+16 in original binary (sub_9AF04 writes to self+16)
}

@synthesize url   = _url;
@synthesize token = _token;

+ (instancetype)sharedInstance {
    static iCdfsIdfdEdfsNdfdftqWer *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[iCdfsIdfdEdfsNdfdftqWer alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _url   = nil;
        _token = nil;
    }
    return self;
}

- (void)dealloc {
    [_url   release];
    [_token release];
    [super dealloc];
}

- (void)login:(NSString *)username
     password:(NSString *)password
     callback:(VCamNetworkCallback)callback
{
    // IDA 0x9ABC8: full URL = [NSString stringWithFormat:@"%@/user/login", self->_url]
    NSString *base = self.url ?: @"kkameugojm.catto.lol";
    NSString *urlString;
    if ([base hasPrefix:@"http"]) {
        urlString = [NSString stringWithFormat:@"%@/user/login", base];
    } else {
        urlString = [NSString stringWithFormat:@"https://%@/user/login", base];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (callback) callback(NO, @"Invalid URL");
        return;
    }

    // IDA 0x9ABC8: timestamp = (uint64_t)([NSDate timeIntervalSince1970] * 1000.0)
    NSString *passHash = md5HexString(password);   // fWerckASqdKhdgSkdhIjddf: full MD5, 32 hex chars
    NSString *hash     = deviceHash();             // fAsdjytEfRgsjYfsgc: base64(SHA-256(Serial+UDID))
    int64_t  ts        = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);

    // IDA: percent-encode body, then dataUsingEncoding:NSUTF8StringEncoding — NO XOR, NO AES
    NSCharacterSet *special = [NSCharacterSet characterSetWithCharactersInString:@"?!@#$^&%*+,:;='\"` <>()[]{}/\\| "];
    NSCharacterSet *allowed = [special invertedSet];
    NSString *encodedUser = [username stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSString *encodedPass = [passHash  stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSString *encodedHash = [hash      stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSString *bodyStr = [NSString stringWithFormat:@"username=%@&password=%@&hash=%@&timestamp=%lld",
                         encodedUser, encodedPass, encodedHash, (long long)ts];
    NSData *bodyData = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody   = bodyData;
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)bodyData.length] forHTTPHeaderField:@"Content-Length"];

    VCamNetworkCallback cb = [callback copy];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || !data) {
            if (cb) cb(NO, error.localizedDescription ?: @"Network error");
            [cb release];
            return;
        }

        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];

        if (!json || ![json isKindOfClass:[NSDictionary class]]) {
            if (cb) cb(NO, @"Invalid response");
            [cb release];
            return;
        }

        NSInteger code = [json[@"code"] integerValue];
        if (code == 0) {
            NSString *tok = json[@"token"];
            if (tok) self.token = tok;
            if (cb) cb(YES, nil);
        } else {
            NSString *msg = json[@"message"] ?: json[@"msg"] ?: [NSString stringWithFormat:@"Error %ld", (long)code];
            if (cb) cb(NO, msg);
        }
        [cb release];
    }];

    [task resume];
    [session finishTasksAndInvalidate];
}

@end
