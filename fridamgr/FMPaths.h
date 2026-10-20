#ifndef FMPATHS_H
#define FMPATHS_H

#import <Foundation/Foundation.h>
#if THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#define FMRootPath(path) jbroot(path)
#else
#import <rootless.h>
#define FMRootPath(path) ROOT_PATH_NS_VAR(path)
#endif

// All processes use the official resolver; no hard-coded .jbroot UUID.
static inline NSString *FMDataPath(NSString *path) {
#if THEOS_PACKAGE_SCHEME_ROOTHIDE
    return FMRootPath(path);
#else
    return path;
#endif
}

static inline NSArray<NSString *> *FMToolSearchPaths(NSString *name) {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *directory in @[@"/usr/bin", @"/usr/sbin", @"/usr/local/bin", @"/usr/local/sbin", @"/bin", @"/sbin"]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        [paths addObject:FMRootPath(path)];
        if (![paths containsObject:path]) [paths addObject:path];
    }
    return paths;
}

static inline NSString *FMToolEnvironmentPath(void) {
    NSMutableArray *directories = [NSMutableArray array];
    for (NSString *directory in @[@"/usr/bin", @"/usr/sbin", @"/usr/local/bin", @"/usr/local/sbin", @"/bin", @"/sbin"]) {
        [directories addObject:FMRootPath(directory)];
        if (![directories containsObject:directory]) [directories addObject:directory];
    }
    return [directories componentsJoinedByString:@":"];
}
#endif
