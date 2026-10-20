#import <Foundation/Foundation.h>
#import "FMDaemon.h"
#import "FMCommon.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in @[kFMPreferencesPlistPath, kFMHistoryPath, kFMLogPath, kFMSocketPath]) {
            [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];
        }
        FMDaemon *daemon = [FMDaemon sharedDaemon];
        [daemon start];
        dispatch_main();
    }
    return 0;
}
