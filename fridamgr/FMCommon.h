#ifndef FMCOMMON_H
#define FMCOMMON_H

#import "FMPaths.h"

#define kFMPreferencesPlistPath FMDataPath(@"/var/mobile/Library/Preferences/com.b1tbreaker.fridamanager.plist")
#define kFMSocketPath FMDataPath(@"/var/run/fridamgr.sock")

#define kFMDefaultPort 27042
#define kFMDefaultListenAddress @"127.0.0.1"

#define kFMLibSandyExtension "com.b1tbreaker.fridamanager.socket"

#define kFMConfigKeyPort @"Port"
#define kFMConfigKeyListenAddress @"ListenAddress"
#define kFMConfigKeyLocalhostOnly @"LocalhostOnly"

// Commands
#define kFMCommandStart @"START"
#define kFMCommandStop @"STOP"
#define kFMCommandRestart @"RESTART"
#define kFMCommandStatus @"STATUS"
#define kFMCommandGetConfig @"GETCONFIG"
#define kFMCommandSetPort @"SETPORT"
#define kFMCommandSetLocalhost @"SETLOCALHOST"
#define kFMCommandListVersions @"LISTVERSIONS"
#define kFMCommandDownload @"DOWNLOAD"
#define kFMCommandDownloadProgress @"DLPROGRESS"
#define kFMCommandGetVersion @"GETVERSION"
#define kFMCommandUninstall @"UNINSTALL"
#define kFMCommandGetLog @"GETLOG"
#define kFMCommandGetHistory @"GETHISTORY"
#define kFMCommandClearHistory @"CLEARHISTORY"

// Managed binary install path (our own copy, separate from Sileo's)
#define kFMManagedBinaryPath FMRootPath(@"/usr/local/bin/frida-server")

// Managed agent dylib install path (needed for spawn/inject)
#define kFMManagedAgentPath FMRootPath(@"/usr/lib/frida/frida-agent.dylib")

// Sileo LaunchDaemon label
#define kFMSileoFridaLabel @"re.frida.server"

// Search paths for frida-server binary
#define kFMFridaServerSearchPaths @[ \
    FMRootPath(@"/usr/sbin/frida-server"), \
    FMRootPath(@"/usr/local/sbin/frida-server"), \
    FMRootPath(@"/usr/bin/frida-server"), \
    FMRootPath(@"/usr/local/bin/frida-server") \
]

// GitHub Atom feed (lightweight, no API rate limit)
#define kFMGitHubAtomURL @"https://github.com/frida/frida/releases.atom"
#define kFMGitHubReleasesPerPage 100

// Log file path
#define kFMLogPath FMDataPath(@"/var/tmp/fridamgr.log")

// Download history file (separate from preferences to avoid cfprefsd conflicts)
#define kFMHistoryPath FMDataPath(@"/var/mobile/Library/com.b1tbreaker.fridamanager.history.plist")

#endif
