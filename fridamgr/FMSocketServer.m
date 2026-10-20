#import "FMSocketServer.h"
#import "FMCommon.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>


@implementation FMSocketServer {
    int _listenFD;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _queue = dispatch_queue_create("com.b1tbreaker.fridamanager.socketserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)startListening {
    const char *socketPath = [kFMSocketPath UTF8String];

    unlink(socketPath);

    _listenFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_listenFD < 0) return NO;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlcpy(addr.sun_path, socketPath, sizeof(addr.sun_path)) >= sizeof(addr.sun_path)) {
        close(_listenFD);
        _listenFD = -1;
        return NO;
    }

    if (bind(_listenFD, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(_listenFD);
        _listenFD = -1;
        return NO;
    }

    chmod(socketPath, 0666);

    if (listen(_listenFD, 16) < 0) {
        close(_listenFD);
        _listenFD = -1;
        return NO;
    }

    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listenFD, 0, _queue);
    dispatch_source_set_event_handler(_acceptSource, ^{
        [self acceptConnection];
    });
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(self->_listenFD);
        self->_listenFD = -1;
    });
    dispatch_resume(_acceptSource);

    return YES;
}

- (void)acceptConnection {
    struct sockaddr_un clientAddr;
    socklen_t clientLen = sizeof(clientAddr);
    int clientFD = accept(_listenFD, (struct sockaddr *)&clientAddr, &clientLen);
    if (clientFD < 0) return;

    // Handle each client on a concurrent queue so slow commands don't block others
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self handleClient:clientFD];
    });
}

- (void)handleClient:(int)clientFD {
    char buffer[4096];
    ssize_t bytesRead = read(clientFD, buffer, sizeof(buffer) - 1);

    if (bytesRead > 0) {
        buffer[bytesRead] = '\0';
        NSString *command = [[NSString alloc] initWithUTF8String:buffer];
        command = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        NSString *response = @"ERR:no handler";
        if (self.delegate) {
            response = [self.delegate handleCommand:command];
        }

        const char *responseBytes = [response UTF8String];
        write(clientFD, responseBytes, strlen(responseBytes));
    }

    close(clientFD);
}

- (void)stopListening {
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
}

- (void)dealloc {
    [self stopListening];
}

@end
