#import "FMSocketClient.h"
#import "FMCommon.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <dlfcn.h>

typedef void (*libSandy_applyProfile_t)(const char *);

@implementation FMSocketClient {
    BOOL _profileApplied;
}

+ (instancetype)sharedClient {
    static FMSocketClient *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FMSocketClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _profileApplied = NO;
    }
    return self;
}

- (void)ensureSandboxAccess {
    if (!_profileApplied) {
        void *handle = dlopen([FMRootPath(@"/usr/lib/libsandy.dylib") fileSystemRepresentation], RTLD_LAZY);
#if !THEOS_PACKAGE_SCHEME_ROOTHIDE
        if (!handle) {
            handle = dlopen("/usr/lib/libsandy.dylib", RTLD_LAZY);
        }
#endif
        if (handle) {
            libSandy_applyProfile_t applyProfile = (libSandy_applyProfile_t)dlsym(handle, "libSandy_applyProfile");
            if (applyProfile) {
                applyProfile(kFMLibSandyExtension);
            }
        }
        _profileApplied = YES;
    }
}

- (NSString *)sendCommand:(NSString *)command {
    [self ensureSandboxAccess];

    int sockFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockFD < 0) return nil;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *socketPath = [kFMSocketPath UTF8String];
    if (strlcpy(addr.sun_path, socketPath, sizeof(addr.sun_path)) >= sizeof(addr.sun_path)) {
        close(sockFD);
        return nil;
    }

    struct timeval timeout;
    timeout.tv_sec = 30;
    timeout.tv_usec = 0;
    setsockopt(sockFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(sockFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    if (connect(sockFD, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sockFD);
        return nil;
    }

    const char *cmdBytes = [command UTF8String];
    write(sockFD, cmdBytes, strlen(cmdBytes));

    // Read response in a loop to handle large responses
    NSMutableData *responseData = [NSMutableData data];
    char buffer[65536];
    ssize_t bytesRead;
    while ((bytesRead = read(sockFD, buffer, sizeof(buffer))) > 0) {
        [responseData appendBytes:buffer length:bytesRead];
    }
    close(sockFD);

    if (responseData.length == 0) return nil;

    return [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
}

- (void)sendCommand:(NSString *)command completion:(void (^)(NSString *response))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *response = [self sendCommand:command];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(response);
            });
        }
    });
}

@end
