#import "FMDownloadManager.h"
#import "FMCommon.h"
#import "FMFridaServer.h"
#import <sys/stat.h>
#import <spawn.h>
#import <compression.h>

void FMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss"];
    NSString *timestamp = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, msg];

    NSLog(@"[FridaManager] %@", msg);

    // Keep log file small: truncate if over 32KB
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kFMLogPath]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:kFMLogPath error:nil];
        if ([attrs fileSize] > 32768) {
            NSString *contents = [NSString stringWithContentsOfFile:kFMLogPath encoding:NSUTF8StringEncoding error:nil];
            if (contents.length > 8192) {
                contents = [contents substringFromIndex:contents.length - 8192];
            }
            [contents writeToFile:kFMLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kFMLogPath];
    if (!fh) {
        [@"" writeToFile:kFMLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([kFMLogPath UTF8String], 0666);
        fh = [NSFileHandle fileHandleForWritingAtPath:kFMLogPath];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

@implementation FMDownloadManager {
    float _downloadProgress;
    BOOL _isDownloading;
    NSString *_downloadStatus;
    NSArray<NSString *> *_cachedVersions;
    NSDate *_cacheTimestamp;
    BOOL _isFetchingReleases;
}

+ (instancetype)sharedManager {
    static FMDownloadManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FMDownloadManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _downloadProgress = -1;
        _isDownloading = NO;
        _downloadStatus = @"Idle";
    }
    return self;
}

- (float)downloadProgress { return _downloadProgress; }
- (BOOL)isDownloading { return _isDownloading; }
- (NSString *)downloadStatus { return _downloadStatus; }
- (NSArray<NSString *> *)cachedVersions { return _cachedVersions; }
- (BOOL)isFetchingReleases { return _isFetchingReleases; }

#pragma mark - Single HTTP method (same approach used for successful downloads)

- (NSData *)httpGet:(NSString *)urlString statusCode:(NSInteger *)outStatusCode {
    FMLog(@"GET %@", urlString);

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        FMLog(@"ERROR: bad URL");
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"FridaManager/2.0" forHTTPHeaderField:@"User-Agent"];
    [request setTimeoutInterval:20];

    __block NSData *resultData = nil;
    __block NSInteger statusCode = 0;
    __block NSError *resultError = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 20;
    config.timeoutIntervalForResource = 120;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        resultData = data;
        resultError = error;
        if ([response isKindOfClass:[NSHTTPURLResponse class]])
            statusCode = ((NSHTTPURLResponse *)response).statusCode;
        dispatch_semaphore_signal(sem);
    }] resume];

    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    [session invalidateAndCancel];

    if (waitResult != 0) {
        FMLog(@"ERROR: timed out");
        if (outStatusCode) *outStatusCode = 0;
        return nil;
    }

    if (resultError) {
        FMLog(@"ERROR: %@ (code %ld)", resultError.localizedDescription, (long)resultError.code);
    }

    FMLog(@"Response: HTTP %ld, %lu bytes", (long)statusCode, (unsigned long)resultData.length);

    if (outStatusCode) *outStatusCode = statusCode;
    if (statusCode >= 400) return nil;
    return resultData;
}

#pragma mark - Download to disk (avoids loading large files into memory)

- (BOOL)downloadFileToPath:(NSString *)destPath fromURL:(NSString *)urlString {
    FMLog(@"Downloading %@ to disk", urlString);

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        FMLog(@"ERROR: bad URL");
        return NO;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"FridaManager/2.0" forHTTPHeaderField:@"User-Agent"];
    [request setTimeoutInterval:30];

    __block NSURL *tmpFileURL = nil;
    __block NSInteger statusCode = 0;
    __block NSError *resultError = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = 300;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    [[session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        resultError = error;
        if ([response isKindOfClass:[NSHTTPURLResponse class]])
            statusCode = ((NSHTTPURLResponse *)response).statusCode;

        if (location && !error) {
            // Move the temp file to our destination before the completion handler returns
            // (the system deletes the temp file after this block)
            [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
            NSError *moveError = nil;
            if ([[NSFileManager defaultManager] moveItemAtURL:location
                                                        toURL:[NSURL fileURLWithPath:destPath]
                                                        error:&moveError]) {
                tmpFileURL = [NSURL fileURLWithPath:destPath];
            } else {
                resultError = moveError;
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];

    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC));
    [session invalidateAndCancel];

    if (waitResult != 0) {
        FMLog(@"ERROR: download timed out");
        return NO;
    }

    if (resultError) {
        FMLog(@"ERROR: %@ (code %ld)", resultError.localizedDescription, (long)resultError.code);
        return NO;
    }

    if (statusCode >= 400) {
        FMLog(@"ERROR: HTTP %ld", (long)statusCode);
        return NO;
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:destPath error:nil];
    FMLog(@"Downloaded: HTTP %ld, %llu bytes on disk", (long)statusCode, [attrs fileSize]);
    return tmpFileURL != nil;
}

#pragma mark - Version Fetching (Atom feed)

- (NSArray<NSString *> *)fetchLatestVersions:(NSInteger)limit {
    if (_cachedVersions && _cacheTimestamp) {
        NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:_cacheTimestamp];
        if (age < 300) {
            FMLog(@"Cache hit: %lu versions (%.0fs old)", (unsigned long)_cachedVersions.count, age);
            return _cachedVersions;
        }
    }

    _isFetchingReleases = YES;

    NSInteger statusCode = 0;
    NSData *data = [self httpGet:kFMGitHubAtomURL statusCode:&statusCode];

    if (!data || data.length == 0) {
        FMLog(@"ERROR: Atom feed empty or failed (HTTP %ld)", (long)statusCode);
        _isFetchingReleases = NO;
        return _cachedVersions;
    }

    NSString *atom = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!atom) {
        FMLog(@"ERROR: Atom response not UTF-8");
        _isFetchingReleases = NO;
        return _cachedVersions;
    }

    // Parse versions using multiple strategies
    NSMutableArray<NSString *> *versions = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    // Strategy 1: <id> tags — e.g. <id>tag:github.com,2008:Repository/xxx/16.7.4</id>
    NSRegularExpression *idRegex = [NSRegularExpression regularExpressionWithPattern:@"<id>[^<]*/([0-9]+\\.[0-9]+\\.[0-9]+)</id>"
                                                                            options:0
                                                                              error:nil];
    NSArray *idMatches = [idRegex matchesInString:atom options:0 range:NSMakeRange(0, atom.length)];
    FMLog(@"Regex strategy 1 (id tags): %lu matches", (unsigned long)idMatches.count);

    for (NSTextCheckingResult *match in idMatches) {
        if (match.numberOfRanges >= 2) {
            NSString *version = [atom substringWithRange:[match rangeAtIndex:1]];
            if (![seen containsObject:version]) {
                [seen addObject:version];
                [versions addObject:version];
            }
        }
    }

    // Strategy 2: <title> tags containing a version — e.g. <title>Frida 16.7.4</title>
    if (versions.count == 0) {
        NSRegularExpression *titleRegex = [NSRegularExpression regularExpressionWithPattern:@"<title[^>]*>[^<]*?(\\d+\\.\\d+\\.\\d+)[^<]*</title>"
                                                                                   options:0
                                                                                     error:nil];
        NSArray *titleMatches = [titleRegex matchesInString:atom options:0 range:NSMakeRange(0, atom.length)];
        FMLog(@"Regex strategy 2 (title tags): %lu matches", (unsigned long)titleMatches.count);

        for (NSTextCheckingResult *match in titleMatches) {
            if (match.numberOfRanges >= 2) {
                NSString *version = [atom substringWithRange:[match rangeAtIndex:1]];
                if (![seen containsObject:version]) {
                    [seen addObject:version];
                    [versions addObject:version];
                }
            }
        }
    }

    // Strategy 3: Any version-like pattern X.Y.Z in the feed
    if (versions.count == 0) {
        NSRegularExpression *anyRegex = [NSRegularExpression regularExpressionWithPattern:@"/tag/(\\d+\\.\\d+\\.\\d+)"
                                                                                 options:0
                                                                                   error:nil];
        NSArray *anyMatches = [anyRegex matchesInString:atom options:0 range:NSMakeRange(0, atom.length)];
        FMLog(@"Regex strategy 3 (/tag/ URLs): %lu matches", (unsigned long)anyMatches.count);

        for (NSTextCheckingResult *match in anyMatches) {
            if (match.numberOfRanges >= 2) {
                NSString *version = [atom substringWithRange:[match rangeAtIndex:1]];
                if (![seen containsObject:version]) {
                    [seen addObject:version];
                    [versions addObject:version];
                }
            }
        }
    }

    if (versions.count > 0) {
        FMLog(@"Found %lu versions: %@", (unsigned long)versions.count, [versions componentsJoinedByString:@", "]);
        _cachedVersions = [versions copy];
        _cacheTimestamp = [NSDate date];
    } else {
        // Log more of the feed for debugging
        NSString *snippet = atom.length > 500 ? [atom substringToIndex:500] : atom;
        snippet = [[snippet componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
        FMLog(@"ERROR: No versions found. Feed: %@", snippet);
    }

    _isFetchingReleases = NO;
    return versions.count > 0 ? versions : _cachedVersions;
}

#pragma mark - Download & Install

- (BOOL)downloadAndInstallVersion:(NSString *)version {
    if (_isDownloading) return NO;

    _isDownloading = YES;
    _downloadProgress = 0;
    _downloadStatus = @"Downloading .deb...";

    NSString *debName = [NSString stringWithFormat:@"frida_%@_iphoneos-arm64.deb", version];
    NSString *downloadURL = [NSString stringWithFormat:
        @"https://github.com/frida/frida/releases/download/%@/%@", version, debName];

    // Download directly to disk (never load the 15MB+ .deb into memory — avoids jetsam kills)
    NSString *tmpDeb = FMDataPath(@"/var/tmp/fridamgr_download.deb");
    NSString *tmpExtract = FMDataPath(@"/var/tmp/fridamgr_extract");

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmpDeb error:nil];
    [fm removeItemAtPath:tmpExtract error:nil];

    BOOL downloaded = [self downloadFileToPath:tmpDeb fromURL:downloadURL];
    if (!downloaded) {
        FMLog(@"ERROR: Download failed for v%@", version);
        _downloadStatus = @"Download failed";
        [fm removeItemAtPath:tmpDeb error:nil];
        _isDownloading = NO;
        _downloadProgress = -1;
        return NO;
    }

    _downloadProgress = 0.5;
    _downloadStatus = @"Extracting...";

    FMLog(@"Downloaded .deb to %@ — extracting", tmpDeb);

    // Extract .deb: parse ar headers (memory-mapped, minimal RAM), then use tar to decompress
    BOOL extracted = [self extractDebAtPath:tmpDeb toDirectory:tmpExtract];
    if (!extracted) {
        FMLog(@"ERROR: dpkg-deb extraction failed");
        [fm removeItemAtPath:tmpDeb error:nil];
        [fm removeItemAtPath:tmpExtract error:nil];
        _downloadStatus = @"Extraction failed";
        _isDownloading = NO;
        _downloadProgress = -1;
        return NO;
    }

    _downloadProgress = 0.7;
    _downloadStatus = @"Installing...";

    // Find frida-server and frida-agent.dylib in the extracted tree
    NSString *serverPath = [self findFileNamed:@"frida-server" inDirectory:tmpExtract];
    NSString *agentPath = [self findFileNamed:@"frida-agent.dylib" inDirectory:tmpExtract];

    if (!serverPath) {
        FMLog(@"ERROR: frida-server not found in extracted .deb");
        [fm removeItemAtPath:tmpDeb error:nil];
        [fm removeItemAtPath:tmpExtract error:nil];
        _downloadStatus = @"Extraction failed — frida-server not found";
        _isDownloading = NO;
        _downloadProgress = -1;
        return NO;
    }

    FMLog(@"Found server: %@", serverPath);
    if (agentPath) FMLog(@"Found agent: %@", agentPath);

    // Install by moving/copying files directly (never load 15-38MB binaries into memory)
    BOOL success = [self installFileAtPath:serverPath toPath:kFMManagedBinaryPath];

    if (success && agentPath) {
        success = [self installFileAtPath:agentPath toPath:kFMManagedAgentPath];
    }

    // Clean up temp files
    [fm removeItemAtPath:tmpDeb error:nil];
    [fm removeItemAtPath:tmpExtract error:nil];

    if (success) {
        _downloadProgress = 1.0;
        _downloadStatus = [NSString stringWithFormat:@"Installed v%@", version];
        [[FMFridaServer sharedServer] refreshBinaryPath];
        FMLog(@"SUCCESS: v%@ installed", version);
    } else {
        _downloadStatus = @"Install failed";
    }

    _isDownloading = NO;
    return success;
}

#pragma mark - Disk-based .deb extraction (avoids jetsam crashes from in-memory decompression)

- (BOOL)extractDebAtPath:(NSString *)debPath toDirectory:(NSString *)outDir {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    [fileMgr createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Step 1: Memory-map the .deb and extract data.tar.* to a temp file
    // Memory-mapping avoids loading 15MB+ into RAM (only pages we read get loaded)
    NSString *arTmp = FMDataPath(@"/var/tmp/fridamgr_ar_tmp");
    [fileMgr removeItemAtPath:arTmp error:nil];
    [fileMgr createDirectoryAtPath:arTmp withIntermediateDirectories:YES attributes:nil error:nil];

    NSData *debData = [NSData dataWithContentsOfFile:debPath options:NSDataReadingMappedIfSafe error:nil];
    if (!debData || debData.length < 8) {
        FMLog(@"ERROR: Failed to mmap .deb");
        [fileMgr removeItemAtPath:arTmp error:nil];
        return NO;
    }

    const uint8_t *bytes = debData.bytes;
    size_t len = debData.length;

    if (memcmp(bytes, "!<arch>\n", 8) != 0) {
        FMLog(@"ERROR: Not a valid ar archive");
        [fileMgr removeItemAtPath:arTmp error:nil];
        return NO;
    }

    // Parse ar headers to find data.tar.* and write it to disk
    NSString *dataTarPath = nil;
    size_t offset = 8;
    while (offset + 60 <= len) {
        char nameField[17] = {0};
        memcpy(nameField, bytes + offset, 16);

        char sizeField[11] = {0};
        memcpy(sizeField, bytes + offset + 48, 10);

        size_t memberSize = (size_t)atol(sizeField);
        size_t dataStart = offset + 60;

        NSString *name = [[NSString stringWithUTF8String:nameField]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];

        FMLog(@"  ar: '%@' (%zu bytes)", name, memberSize);

        if ([name hasPrefix:@"data.tar"] && dataStart + memberSize <= len) {
            dataTarPath = [arTmp stringByAppendingPathComponent:name];

            // Write data.tar.* to disk using file handle to avoid memory copy
            NSFileHandle *fh = nil;
            [fileMgr createFileAtPath:dataTarPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:dataTarPath];
            if (!fh) {
                FMLog(@"ERROR: Cannot create %@", dataTarPath);
                break;
            }

            // Write in chunks to keep memory low
            size_t chunkSize = 512 * 1024; // 512KB chunks
            size_t written = 0;
            while (written < memberSize) {
                size_t toWrite = MIN(chunkSize, memberSize - written);
                NSData *chunk = [NSData dataWithBytesNoCopy:(void *)(bytes + dataStart + written)
                                                     length:toWrite
                                               freeWhenDone:NO];
                [fh writeData:chunk];
                written += toWrite;
            }
            [fh closeFile];

            FMLog(@"Extracted %@ to disk (%zu bytes)", name, memberSize);
            break;
        }

        offset = dataStart + memberSize;
        if (offset % 2 != 0) offset++;
    }

    // Release the memory-mapped .deb
    debData = nil;

    if (!dataTarPath) {
        FMLog(@"ERROR: data.tar.* not found in .deb");
        [fileMgr removeItemAtPath:arTmp error:nil];
        return NO;
    }

    // Step 2: Decompress XZ to tar using Apple's compression framework (streaming to disk)
    // This avoids needing external xz/tar tools and keeps memory usage minimal
    NSString *tarPath = nil;

    if ([dataTarPath hasSuffix:@".xz"]) {
        tarPath = [arTmp stringByAppendingPathComponent:@"data.tar"];
        FMLog(@"Decompressing XZ to disk using compression framework...");
        if (![self decompressXZFile:dataTarPath toFile:tarPath]) {
            FMLog(@"ERROR: XZ decompression to disk failed");
            [fileMgr removeItemAtPath:arTmp error:nil];
            return NO;
        }
        // Remove the compressed file to free disk space
        [fileMgr removeItemAtPath:dataTarPath error:nil];
    } else {
        tarPath = dataTarPath;
    }

    // Step 3: Parse tar on disk and extract only the files we need (frida-server, frida-agent.dylib)
    FMLog(@"Parsing tar to extract files...");
    if (![self extractFilesFromTar:tarPath toDirectory:outDir]) {
        FMLog(@"ERROR: tar parsing failed");
        [fileMgr removeItemAtPath:arTmp error:nil];
        return NO;
    }

    [fileMgr removeItemAtPath:arTmp error:nil];
    return YES;
}

#pragma mark - XZ decompression (streaming to disk)

- (BOOL)decompressXZFile:(NSString *)xzPath toFile:(NSString *)outPath {
    // Memory-map the XZ file
    NSData *xzData = [NSData dataWithContentsOfFile:xzPath options:NSDataReadingMappedIfSafe error:nil];
    if (!xzData || xzData.length < 12) return NO;

    const uint8_t *srcBytes = (const uint8_t *)xzData.bytes;

    // Verify XZ magic
    if (srcBytes[0] != 0xFD || srcBytes[1] != 0x37 || srcBytes[2] != 0x7A ||
        srcBytes[3] != 0x58 || srcBytes[4] != 0x5A || srcBytes[5] != 0x00) {
        FMLog(@"ERROR: Not XZ format");
        return NO;
    }

    // Create output file
    [[NSFileManager defaultManager] createFileAtPath:outPath contents:nil attributes:nil];
    NSFileHandle *outHandle = [NSFileHandle fileHandleForWritingAtPath:outPath];
    if (!outHandle) {
        FMLog(@"ERROR: Cannot create output file %@", outPath);
        return NO;
    }

    // Try decompressing with different XZ header offsets
    NSArray *offsets = @[@(0), @(12)];

    for (NSNumber *offsetNum in offsets) {
        size_t srcOffset = [offsetNum unsignedLongValue];
        if (srcOffset >= xzData.length) continue;

        // For offset 12, also try skipping the block header
        NSMutableArray *tryOffsets = [NSMutableArray arrayWithObject:offsetNum];
        if (srcOffset == 12 && xzData.length > 16) {
            uint8_t blockHeaderSizeByte = srcBytes[12];
            if (blockHeaderSizeByte > 0) {
                size_t blockHeaderSize = (blockHeaderSizeByte + 1) * 4;
                size_t dataOffset = 12 + blockHeaderSize;
                if (dataOffset < xzData.length) {
                    [tryOffsets addObject:@(dataOffset)];
                }
            }
        }

        for (NSNumber *tryOffset in tryOffsets) {
            size_t off = [tryOffset unsignedLongValue];
            [outHandle truncateFileAtOffset:0];
            [outHandle seekToFileOffset:0];

            if ([self streamDecompress:srcBytes + off
                               length:xzData.length - off
                             toHandle:outHandle]) {
                unsigned long long fileSize = [outHandle seekToEndOfFile];
                [outHandle closeFile];
                FMLog(@"Decompressed: %llu bytes on disk", fileSize);
                return YES;
            }
        }
    }

    [outHandle closeFile];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    FMLog(@"ERROR: All XZ decompression approaches failed");
    return NO;
}

- (BOOL)streamDecompress:(const uint8_t *)src length:(size_t)srcLen toHandle:(NSFileHandle *)outHandle {
    // Use a small buffer — write to disk frequently to keep memory low
    size_t bufSize = 256 * 1024; // 256KB buffer
    uint8_t *buf = malloc(bufSize);
    if (!buf) return NO;

    compression_stream stream;
    compression_status status;

    status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA);
    if (status != COMPRESSION_STATUS_OK) {
        free(buf);
        return NO;
    }

    stream.src_ptr = src;
    stream.src_size = srcLen;
    stream.dst_ptr = buf;
    stream.dst_size = bufSize;

    BOOL success = NO;

    while (1) {
        status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);

        size_t produced = stream.dst_ptr - buf;
        if (produced > 0) {
            @autoreleasepool {
                [outHandle writeData:[NSData dataWithBytesNoCopy:buf length:produced freeWhenDone:NO]];
            }
            stream.dst_ptr = buf;
            stream.dst_size = bufSize;
        }

        if (status == COMPRESSION_STATUS_END) { success = YES; break; }
        else if (status == COMPRESSION_STATUS_ERROR) break;
        if (stream.src_size == 0) break;
    }

    compression_stream_destroy(&stream);
    free(buf);
    return success;
}

#pragma mark - Tar parsing (disk-based, memory-mapped)

- (BOOL)extractFilesFromTar:(NSString *)tarPath toDirectory:(NSString *)outDir {
    NSData *tarData = [NSData dataWithContentsOfFile:tarPath options:NSDataReadingMappedIfSafe error:nil];
    if (!tarData || tarData.length < 512) {
        FMLog(@"ERROR: Cannot mmap tar file");
        return NO;
    }

    const uint8_t *bytes = tarData.bytes;
    size_t len = tarData.length;
    size_t offset = 0;
    BOOL foundAny = NO;

    NSSet *targets = [NSSet setWithArray:@[@"frida-server", @"frida-agent.dylib"]];

    while (offset + 512 <= len) {
        const char *header = (const char *)(bytes + offset);

        BOOL allZero = YES;
        for (int i = 0; i < 512; i++) {
            if (header[i] != 0) { allZero = NO; break; }
        }
        if (allZero) break;

        char nameField[101] = {0};
        memcpy(nameField, header, 100);
        NSString *entryName = [NSString stringWithUTF8String:nameField];

        char prefixField[156] = {0};
        memcpy(prefixField, header + 345, 155);
        if (prefixField[0] != 0) {
            NSString *prefix = [NSString stringWithUTF8String:prefixField];
            entryName = [NSString stringWithFormat:@"%@/%@", prefix, entryName];
        }

        char sizeField[13] = {0};
        memcpy(sizeField, header + 124, 12);
        size_t fileSize = (size_t)strtoul(sizeField, NULL, 8);

        char typeFlag = header[156];
        size_t dataOffset = offset + 512;

        if ((typeFlag == '0' || typeFlag == 0) && fileSize > 0) {
            NSString *lastComponent = [entryName lastPathComponent];
            if ([targets containsObject:lastComponent] && dataOffset + fileSize <= len) {
                // Write this file to the output directory
                NSString *destPath = [outDir stringByAppendingPathComponent:lastComponent];
                FMLog(@"Extracting '%@' (%zu bytes)", entryName, fileSize);

                [[NSFileManager defaultManager] createFileAtPath:destPath contents:nil attributes:nil];
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:destPath];
                if (fh) {
                    // Write in chunks from memory-mapped data
                    size_t chunkSize = 512 * 1024;
                    size_t written = 0;
                    while (written < fileSize) {
                        @autoreleasepool {
                            size_t toWrite = MIN(chunkSize, fileSize - written);
                            [fh writeData:[NSData dataWithBytesNoCopy:(void *)(bytes + dataOffset + written)
                                                              length:toWrite
                                                        freeWhenDone:NO]];
                            written += toWrite;
                        }
                    }
                    [fh closeFile];
                    foundAny = YES;
                }
            }
        }

        size_t blocks = (fileSize + 511) / 512;
        offset = dataOffset + (blocks * 512);
    }

    return foundAny;
}

- (NSString *)findFileNamed:(NSString *)name inDirectory:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:dir];
    NSString *path;
    while ((path = [enumerator nextObject])) {
        if ([[path lastPathComponent] isEqualToString:name]) {
            NSString *fullPath = [dir stringByAppendingPathComponent:path];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && !isDir) {
                return fullPath;
            }
        }
    }
    return nil;
}

- (NSString *)findToolNamed:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in FMToolSearchPaths(name)) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (int)runTool:(NSString *)tool args:(NSArray<NSString *> *)args {
    return [self runTool:tool args:args workDir:nil];
}

- (int)runTool:(NSString *)tool args:(NSArray<NSString *> *)args workDir:(NSString *)workDir {
    NSMutableString *cmdLog = [NSMutableString stringWithString:tool];
    for (NSString *a in args) [cmdLog appendFormat:@" %@", a];
    FMLog(@"Running: %@", cmdLog);

    int argc = (int)args.count + 1;
    const char **argv = calloc(argc + 1, sizeof(char *));
    argv[0] = [tool UTF8String];
    for (int i = 0; i < (int)args.count; i++) {
        argv[i + 1] = [args[i] UTF8String];
    }
    argv[argc] = NULL;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // Change working directory if specified
    NSString *origDir = nil;
    if (workDir) {
        origDir = [[NSFileManager defaultManager] currentDirectoryPath];
        [[NSFileManager defaultManager] changeCurrentDirectoryPath:workDir];
    }

    // Build environment with comprehensive PATH so tools can find each other (xz, gzip, etc.)
    // The daemon's default environment has a minimal PATH that misses jailbreak paths
    extern char **environ;
    NSMutableDictionary *envDict = [NSMutableDictionary dictionary];
    for (int i = 0; environ[i]; i++) {
        NSString *entry = [NSString stringWithUTF8String:environ[i]];
        NSRange eq = [entry rangeOfString:@"="];
        if (eq.location != NSNotFound) {
            NSString *key = [entry substringToIndex:eq.location];
            NSString *val = [entry substringFromIndex:eq.location + 1];
            envDict[key] = val;
        }
    }
    envDict[@"PATH"] = FMToolEnvironmentPath();

    NSMutableArray *envArray = [NSMutableArray array];
    for (NSString *key in envDict) {
        [envArray addObject:[NSString stringWithFormat:@"%@=%@", key, envDict[key]]];
    }
    const char **envp = calloc(envArray.count + 1, sizeof(char *));
    for (int i = 0; i < (int)envArray.count; i++) {
        envp[i] = [envArray[i] UTF8String];
    }
    envp[envArray.count] = NULL;

    pid_t pid = 0;
    int ret = posix_spawn(&pid, [tool UTF8String], &actions, &attr, (char *const *)argv, (char *const *)envp);

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    free(argv);
    free(envp);

    if (ret != 0) {
        FMLog(@"spawn failed: %d", ret);
        if (origDir) [[NSFileManager defaultManager] changeCurrentDirectoryPath:origDir];
        return -1;
    }

    int status = 0;
    waitpid(pid, &status, 0);

    if (origDir) [[NSFileManager defaultManager] changeCurrentDirectoryPath:origDir];

    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    FMLog(@"Exit code: %d", exitCode);
    return exitCode;
}

#pragma mark - Install (file-based, no memory loading)

- (BOOL)installFileAtPath:(NSString *)srcPath toPath:(NSString *)installPath {
    NSFileManager *fileMgr = [NSFileManager defaultManager];

    NSString *dir = [installPath stringByDeletingLastPathComponent];
    [fileMgr createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    // Remove existing file
    [fileMgr removeItemAtPath:installPath error:nil];

    // Copy file directly — no need to load into memory
    NSError *error = nil;
    if (![fileMgr copyItemAtPath:srcPath toPath:installPath error:&error]) {
        FMLog(@"ERROR: copy failed %@ -> %@: %@", srcPath, installPath, error);
        return NO;
    }

    chmod([installPath UTF8String], 0755);
    chown([installPath UTF8String], 0, 0);

    FMLog(@"Installed %@ to %@", [srcPath lastPathComponent], installPath);
    return YES;
}

// Legacy methods kept for compatibility
- (BOOL)installBinary:(NSData *)binaryData {
    NSString *installPath = kFMManagedBinaryPath;

    NSString *dir = [installPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    if (![binaryData writeToFile:installPath atomically:YES]) {
        FMLog(@"ERROR: write failed: %@", installPath);
        return NO;
    }

    chmod([installPath UTF8String], 0755);
    chown([installPath UTF8String], 0, 0);

    FMLog(@"Installed to %@", installPath);
    return YES;
}

- (BOOL)installAgent:(NSData *)agentData {
    NSString *installPath = kFMManagedAgentPath;

    NSString *dir = [installPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    if (![agentData writeToFile:installPath atomically:YES]) {
        FMLog(@"ERROR: agent write failed: %@", installPath);
        return NO;
    }

    chmod([installPath UTF8String], 0755);
    chown([installPath UTF8String], 0, 0);

    FMLog(@"Installed agent to %@", installPath);
    return YES;
}

@end
