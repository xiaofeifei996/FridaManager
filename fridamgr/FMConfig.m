#import "FMConfig.h"
#import "FMCommon.h"
#import <sys/stat.h>

@implementation FMConfig

+ (instancetype)sharedConfig {
    static FMConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FMConfig alloc] init];
        [instance reload];
    });
    return instance;
}

- (void)reload {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kFMPreferencesPlistPath];
    if (prefs) {
        NSNumber *portNum = prefs[kFMConfigKeyPort];
        _port = portNum ? [portNum integerValue] : kFMDefaultPort;

        NSNumber *localhostNum = prefs[kFMConfigKeyLocalhostOnly];
        _localhostOnly = localhostNum ? [localhostNum boolValue] : YES;
    } else {
        _port = kFMDefaultPort;
        _localhostOnly = YES;
        [self save];
    }
}

- (void)save {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kFMPreferencesPlistPath] ?: [NSMutableDictionary dictionary];
    prefs[kFMConfigKeyPort] = @(_port);
    prefs[kFMConfigKeyLocalhostOnly] = @(_localhostOnly);
    [prefs writeToFile:kFMPreferencesPlistPath atomically:YES];
}

- (NSString *)listenAddress {
    return _localhostOnly ? @"127.0.0.1" : @"0.0.0.0";
}

#pragma mark - Download History

- (void)addDownloadHistoryEntry:(NSString *)version {
    NSMutableArray *history = [self loadHistoryArray];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm"];
    NSString *dateStr = [df stringFromDate:[NSDate date]];

    NSDictionary *entry = @{
        @"version": version,
        @"date": dateStr
    };

    // Add newest at the top
    [history insertObject:entry atIndex:0];

    // Keep max 50 entries
    if (history.count > 50) {
        history = [[history subarrayWithRange:NSMakeRange(0, 50)] mutableCopy];
    }

    [self saveHistoryArray:history];
}

- (NSArray<NSDictionary *> *)downloadHistory {
    return [self loadHistoryArray];
}

- (void)clearDownloadHistory {
    [[NSFileManager defaultManager] removeItemAtPath:kFMHistoryPath error:nil];
}

#pragma mark - History File I/O (separate from preferences to avoid cfprefsd conflicts)

- (NSMutableArray *)loadHistoryArray {
    NSArray *arr = [NSArray arrayWithContentsOfFile:kFMHistoryPath];
    return arr ? [arr mutableCopy] : [NSMutableArray array];
}

- (void)saveHistoryArray:(NSArray *)history {
    [history writeToFile:kFMHistoryPath atomically:YES];
    chmod([kFMHistoryPath UTF8String], 0644);
}

@end
