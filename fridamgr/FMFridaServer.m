#import "FMFridaServer.h"
#import "FMCommon.h"
#import "FMDownloadManager.h" // for FMLog
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <sys/sysctl.h>
#import <sys/proc.h> // for SZOMB

extern char **environ;

@implementation FMFridaServer {
    pid_t _serverPID;
    NSString *_binaryPath;
    NSInteger _activePort;
    NSString *_installedVersion;
    FMFridaSource _source;
}

+ (instancetype)sharedServer {
    static FMFridaServer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FMFridaServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverPID = 0;
        _activePort = 0;
        _source = FMFridaSourceNone;
        _binaryPath = [self detectBinaryPath];
        _installedVersion = [self detectVersion];
        [self detectRunningFridaServer];
    }
    return self;
}

- (NSString *)detectBinaryPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *foundPath = nil;

    for (NSString *path in kFMFridaServerSearchPaths) {
        if ([fm isExecutableFileAtPath:path]) {
            foundPath = path;
            break;
        }
    }

    if (!foundPath) {
        _source = FMFridaSourceNone;
        return nil;
    }

    // Determine source: if it's our managed path, it's ours.
    // Otherwise, check for a launchd plist (indicates package manager install).
    if ([foundPath isEqualToString:kFMManagedBinaryPath]) {
        _source = FMFridaSourceFridaManager;
    } else if ([self sileoLaunchDaemonPlist] != nil) {
        _source = FMFridaSourcePackageManager;
    } else {
        // Binary exists at a system path but no launchd plist — treat as package manager
        _source = FMFridaSourcePackageManager;
    }

    return foundPath;
}

- (FMFridaSource)source {
    return _source;
}

- (NSString *)detectVersion {
    if (!_binaryPath) return nil;

    int pipefd[2];
    if (pipe(pipefd) != 0) return nil;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    const char *argv[] = {
        [_binaryPath UTF8String],
        "--version",
        NULL
    };

    pid_t pid = 0;
    int ret = posix_spawn(&pid, argv[0], &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);

    if (ret != 0) {
        close(pipefd[0]);
        return nil;
    }

    char buf[256];
    ssize_t bytesRead = read(pipefd[0], buf, sizeof(buf) - 1);
    close(pipefd[0]);

    int status;
    waitpid(pid, &status, 0);

    if (bytesRead <= 0) return nil;

    buf[bytesRead] = '\0';
    NSString *version = [[NSString stringWithUTF8String:buf]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return version.length > 0 ? version : nil;
}

- (void)refreshBinaryPath {
    _binaryPath = [self detectBinaryPath]; // also updates _source
    _installedVersion = [self detectVersion];
}

- (void)detectRunningFridaServer {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;

    struct kinfo_proc *procs = malloc(size);
    if (!procs) return;

    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        int count = (int)(size / sizeof(struct kinfo_proc));
        for (int i = 0; i < count; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, "frida-server") == 0
                && procs[i].kp_proc.p_stat != SZOMB) {
                _serverPID = procs[i].kp_proc.p_pid;
                if (_activePort == 0) _activePort = kFMDefaultPort;
                break;
            }
        }
    }
    free(procs);
}

- (BOOL)isRunning {
    if (_serverPID > 0) {
        if (kill(_serverPID, 0) == 0) {
            return YES;
        }
        _serverPID = 0;
        _activePort = 0;
    }

    [self detectRunningFridaServer];
    return (_serverPID > 0);
}

- (pid_t)serverPID {
    return _serverPID;
}

- (NSString *)binaryPath {
    if (!_binaryPath) {
        _binaryPath = [self detectBinaryPath];
    }
    return _binaryPath;
}

- (NSInteger)activePort {
    return _activePort;
}

- (NSString *)installedVersion {
    return _installedVersion;
}

#pragma mark - Sileo LaunchDaemon management

- (NSString *)sileoLaunchDaemonPlist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        FMRootPath(@"/Library/LaunchDaemons/re.frida.server.plist"),
        @"/Library/LaunchDaemons/re.frida.server.plist"
    ];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (NSString *)findBinaryNamed:(NSString *)name {
    NSArray<NSString *> *searchPaths = FMToolSearchPaths(name);

    FMLog(@"Searching for %@ in %lu paths...", name, (unsigned long)searchPaths.count);
    for (NSString *path in searchPaths) {
        if (access([path UTF8String], X_OK) == 0) {
            FMLog(@"Found %@ at: %@", name, path);
            return path;
        }
    }
    FMLog(@"%@ not found in any path", name);
    return nil;
}

- (int)runLaunchctl:(NSArray<NSString *> *)args {
    // Find launchctl (cached after first successful find)
    static NSString *launchctlPath = nil;
    if (!launchctlPath) {
        launchctlPath = [self findBinaryNamed:@"launchctl"];
    }

    if (launchctlPath) {
        // Direct execution
        int argc = (int)args.count + 1;
        const char **argv = calloc(argc + 1, sizeof(char *));
        argv[0] = [launchctlPath UTF8String];
        for (int i = 0; i < (int)args.count; i++) {
            argv[i + 1] = [args[i] UTF8String];
        }
        argv[argc] = NULL;

        NSMutableString *cmdLog = [NSMutableString stringWithFormat:@"%@", launchctlPath];
        for (NSString *a in args) [cmdLog appendFormat:@" %@", a];
        FMLog(@"Running: %@", cmdLog);

        pid_t pid = 0;
        int ret = posix_spawn(&pid, [launchctlPath UTF8String], NULL, NULL, (char *const *)argv, environ);
        free(argv);

        if (ret != 0) {
            FMLog(@"launchctl spawn failed: %d", ret);
            return -1;
        }
        int status = 0;
        waitpid(pid, &status, 0);
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        FMLog(@"Result: %d", exitCode);
        return exitCode;
    }

    // Fallback: try via shell
    NSString *shellPath = [self findBinaryNamed:@"sh"];
    if (!shellPath) shellPath = [self findBinaryNamed:@"bash"];
    if (!shellPath) shellPath = [self findBinaryNamed:@"zsh"];

    if (shellPath) {
        NSMutableString *cmd = [NSMutableString stringWithString:@"launchctl"];
        for (NSString *arg in args) {
            [cmd appendFormat:@" '%@'", arg];
        }
        FMLog(@"Running via shell (%@): %@", shellPath, cmd);

        const char *argv[] = {[shellPath UTF8String], "-c", [cmd UTF8String], NULL};
        pid_t pid = 0;
        int ret = posix_spawn(&pid, [shellPath UTF8String], NULL, NULL, (char *const *)argv, environ);
        if (ret != 0) {
            FMLog(@"shell spawn failed: %d", ret);
            return -1;
        }
        int status = 0;
        waitpid(pid, &status, 0);
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        FMLog(@"Result: %d", exitCode);
        return exitCode;
    }

    FMLog(@"No launchctl or shell found - cannot run command");
    return -1;
}

- (void)bootoutSileoFrida {
    // Try 1: bootout with service target (modern launchctl)
    int rc = [self runLaunchctl:@[@"bootout", @"system/re.frida.server"]];
    FMLog(@"bootout system/re.frida.server -> exit %d", rc);

    if (rc != 0) {
        // Try 2: bootout with plist path
        NSString *plist = [self sileoLaunchDaemonPlist];
        if (plist) {
            rc = [self runLaunchctl:@[@"bootout", @"system", plist]];
            FMLog(@"bootout system %@ -> exit %d", plist, rc);
        }
    }

    if (rc != 0) {
        // Try 3: legacy unload
        NSString *plist = [self sileoLaunchDaemonPlist];
        if (plist) {
            rc = [self runLaunchctl:@[@"unload", @"-w", plist]];
            FMLog(@"unload -w %@ -> exit %d", plist, rc);
        }
    }
}

- (void)bootstrapSileoFrida {
    NSString *plist = [self sileoLaunchDaemonPlist];
    if (!plist) {
        FMLog(@"bootstrap: no launchd plist found");
        return;
    }

    // Try 1: modern bootstrap
    int rc = [self runLaunchctl:@[@"bootstrap", @"system", plist]];
    FMLog(@"bootstrap system %@ -> exit %d", plist, rc);

    if (rc != 0) {
        // Try 2: legacy load
        rc = [self runLaunchctl:@[@"load", @"-w", plist]];
        FMLog(@"load -w %@ -> exit %d", plist, rc);
    }
}

#pragma mark - Start / Stop / Restart

- (BOOL)startWithPort:(NSInteger)port listenAddress:(NSString *)address {
    if (self.isRunning) return YES;

    _binaryPath = [self detectBinaryPath];
    if (!_binaryPath) return NO;

    // Package manager installs: use launchctl bootstrap to start
    if (_source == FMFridaSourcePackageManager) {
        [self bootstrapSileoFrida];
        // Give launchd a moment to spawn
        usleep(500000);
        [self detectRunningFridaServer];
        if (_serverPID > 0) {
            _activePort = port;
            return YES;
        }
        return NO;
    }

    // FridaManager installs: spawn directly
    NSString *listenArg = [NSString stringWithFormat:@"%@:%ld", address, (long)port];

    const char *argv[] = {
        [_binaryPath UTF8String],
        "-l",
        [listenArg UTF8String],
        NULL
    };

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    pid_t pid = 0;
    int ret = posix_spawn(&pid, argv[0], NULL, &attr, (char *const *)argv, environ);
    posix_spawnattr_destroy(&attr);

    if (ret != 0) return NO;

    _serverPID = pid;
    _activePort = port;
    return YES;
}

- (BOOL)stop {
    if (_source == FMFridaSourcePackageManager) {
        // Package manager installs: use launchctl bootout to stop cleanly
        FMLog(@"Stopping package manager frida via bootout...");
        [self bootoutSileoFrida];
        // Wait for launchd to kill the process
        usleep(500000);
        // Force kill any remaining frida processes
        [self killAllFridaProcesses];
        usleep(200000);
        // Verify it's actually dead
        [self detectRunningFridaServer];
        if (_serverPID > 0) {
            FMLog(@"Process still alive after bootout, force killing PID %d", _serverPID);
            kill(_serverPID, SIGKILL);
            usleep(200000);
        }
        _serverPID = 0;
        _activePort = 0;
        return YES;
    }

    // FridaManager installs: SIGTERM our spawned process
    if (_serverPID > 0) {
        kill(_serverPID, SIGTERM);
        // Brief wait for graceful shutdown
        int status;
        for (int i = 0; i < 5; i++) {
            pid_t result = waitpid(_serverPID, &status, WNOHANG);
            if (result == _serverPID || (result == -1 && errno == ECHILD)) break;
            usleep(100000); // 100ms, max 500ms total
        }
        // Force kill if still alive
        if (kill(_serverPID, 0) == 0) {
            kill(_serverPID, SIGKILL);
            waitpid(_serverPID, &status, WNOHANG);
        }
        _serverPID = 0;
        _activePort = 0;
    }

    // Kill any remaining frida-server processes and wait for them to die
    [self killAllFridaProcesses];
    usleep(300000); // 300ms for processes to fully exit
    _serverPID = 0;
    _activePort = 0;
    return YES;
}

- (void)killAllFridaProcesses {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;

    struct kinfo_proc *procs = malloc(size);
    if (!procs) return;

    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        int count = (int)(size / sizeof(struct kinfo_proc));
        for (int i = 0; i < count; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, "frida-server") == 0) {
                kill(procs[i].kp_proc.p_pid, SIGKILL);
            }
        }
    }
    free(procs);
}

- (BOOL)restartWithPort:(NSInteger)port listenAddress:(NSString *)address {
    // Don't use [self stop] + [self start] — the zombie process from stop
    // can trick isRunning into thinking frida is still alive.
    // Instead: kill everything, then spawn fresh without checking isRunning.

    if (_source == FMFridaSourcePackageManager) {
        [self bootoutSileoFrida];
        usleep(500000);
    }

    if (_serverPID > 0) {
        kill(_serverPID, SIGTERM);
        int status;
        for (int i = 0; i < 5; i++) {
            pid_t result = waitpid(_serverPID, &status, WNOHANG);
            if (result == _serverPID || (result == -1 && errno == ECHILD)) break;
            usleep(100000);
        }
        if (kill(_serverPID, 0) == 0) {
            kill(_serverPID, SIGKILL);
            waitpid(_serverPID, &status, WNOHANG);
        }
    }

    [self killAllFridaProcesses];
    usleep(500000);

    _serverPID = 0;
    _activePort = 0;

    // Now start fresh
    _binaryPath = [self detectBinaryPath];
    if (!_binaryPath) return NO;

    if (_source == FMFridaSourcePackageManager) {
        [self bootstrapSileoFrida];
        usleep(500000);
        [self detectRunningFridaServer];
        if (_serverPID > 0) {
            _activePort = port;
            return YES;
        }
        return NO;
    }

    NSString *listenArg = [NSString stringWithFormat:@"%@:%ld", address, (long)port];
    const char *argv[] = {
        [_binaryPath UTF8String],
        "-l",
        [listenArg UTF8String],
        NULL
    };

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    pid_t pid = 0;
    int ret = posix_spawn(&pid, argv[0], NULL, &attr, (char *const *)argv, environ);
    posix_spawnattr_destroy(&attr);

    if (ret != 0) return NO;

    _serverPID = pid;
    _activePort = port;
    return YES;
}

- (NSString *)sourceString {
    switch (_source) {
        case FMFridaSourceFridaManager: return @"FridaManager";
        case FMFridaSourcePackageManager: return @"Package Manager";
        default: return @"none";
    }
}

- (NSDictionary *)statusDictionary {
    // Re-scan binary on every status check to detect installs/uninstalls from package managers
    [self refreshBinaryPath];

    BOOL running = self.isRunning;
    BOOL installed = (_binaryPath != nil);
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"running"] = @(running);
    dict[@"installed"] = @(installed);
    dict[@"pid"] = @(_serverPID);
    dict[@"port"] = @(_activePort);
    dict[@"binaryPath"] = _binaryPath ?: @"not found";
    dict[@"version"] = _installedVersion ?: @"unknown";
    dict[@"source"] = [self sourceString];
    return dict;
}

@end
