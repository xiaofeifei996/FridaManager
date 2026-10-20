#import "FMRootListController.h"
#import "FMSocketClient.h"
#import "FMCommon.h"
#import "FMChinese.h"

#pragma mark - Main Settings Controller

@interface FMRootListController ()
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic, strong) PSSpecifier *statusSpecifier;
@property (nonatomic, strong) PSSpecifier *portStatusSpecifier;
@property (nonatomic, strong) PSSpecifier *binaryPathSpecifier;
@property (nonatomic, strong) PSSpecifier *versionSpecifier;
@property (nonatomic, strong) PSSpecifier *sourceSpecifier;
@property (nonatomic, copy) NSString *pendingCustomVersion;
@property (nonatomic, strong) NSDictionary *cachedStatus;
@property (nonatomic, strong) PSSpecifier *customVersionSpecifier;
@end

@implementation FMRootListController

- (NSString *)title { return @"Frida 管理器"; }

- (instancetype)init {
    self = [super init];
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self buildSpecifiers] mutableCopy];
    }
    return _specifiers;
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    // === STATUS GROUP ===
    PSSpecifier *statusGroup = [PSSpecifier groupSpecifierWithName:@"状态"];
    [specs addObject:statusGroup];

    _statusSpecifier = [PSSpecifier preferenceSpecifierNamed:@"服务状态"
                                                     target:self
                                                        set:nil
                                                        get:@selector(getStatusValue:)
                                                     detail:nil
                                                       cell:PSTitleValueCell
                                                       edit:nil];
    [_statusSpecifier setProperty:@"serverStatus" forKey:@"key"];
    [specs addObject:_statusSpecifier];

    _portStatusSpecifier = [PSSpecifier preferenceSpecifierNamed:@"当前端口"
                                                         target:self
                                                            set:nil
                                                            get:@selector(getPortStatusValue:)
                                                         detail:nil
                                                           cell:PSTitleValueCell
                                                           edit:nil];
    [_portStatusSpecifier setProperty:@"activePort" forKey:@"key"];
    [specs addObject:_portStatusSpecifier];

    _binaryPathSpecifier = [PSSpecifier preferenceSpecifierNamed:@"程序路径"
                                                         target:self
                                                            set:nil
                                                            get:@selector(getBinaryPathValue:)
                                                         detail:nil
                                                           cell:PSTitleValueCell
                                                           edit:nil];
    [_binaryPathSpecifier setProperty:@"binaryPath" forKey:@"key"];
    [specs addObject:_binaryPathSpecifier];

    _versionSpecifier = [PSSpecifier preferenceSpecifierNamed:@"版本"
                                                      target:self
                                                         set:nil
                                                         get:@selector(getVersionValue:)
                                                      detail:nil
                                                        cell:PSTitleValueCell
                                                        edit:nil];
    [_versionSpecifier setProperty:@"version" forKey:@"key"];
    [specs addObject:_versionSpecifier];

    _sourceSpecifier = [PSSpecifier preferenceSpecifierNamed:@"安装来源"
                                                      target:self
                                                         set:nil
                                                         get:@selector(getSourceValue:)
                                                      detail:nil
                                                        cell:PSTitleValueCell
                                                        edit:nil];
    [_sourceSpecifier setProperty:@"source" forKey:@"key"];
    [specs addObject:_sourceSpecifier];

    // === CONFIGURATION GROUP ===
    PSSpecifier *configGroup = [PSSpecifier groupSpecifierWithName:@"配置"];
    [configGroup setProperty:@"修改将在下次启动或重启服务时生效。" forKey:@"footerText"];
    [specs addObject:configGroup];

    PSSpecifier *portSpec = [PSSpecifier preferenceSpecifierNamed:@"端口"
                                                          target:self
                                                             set:@selector(setPortValue:specifier:)
                                                             get:@selector(getPortValue:)
                                                          detail:nil
                                                            cell:PSEditTextCell
                                                            edit:nil];
    [portSpec setProperty:@"Port" forKey:@"key"];
    [portSpec setProperty:@(YES) forKey:@"isNumeric"];
    [portSpec setProperty:@(UIKeyboardTypeNumberPad) forKey:@"keyboardType"];
    [portSpec setProperty:@"27042" forKey:@"placeholder"];
    [specs addObject:portSpec];

    PSSpecifier *localhostSpec = [PSSpecifier preferenceSpecifierNamed:@"仅限本机 / USB（禁用 Wi-Fi）"
                                                               target:self
                                                                  set:@selector(setLocalhostValue:specifier:)
                                                                  get:@selector(getLocalhostValue:)
                                                               detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
    [localhostSpec setProperty:@"LocalhostOnly" forKey:@"key"];
    [localhostSpec setProperty:@(YES) forKey:@"default"];
    [specs addObject:localhostSpec];

    // === CONTROLS GROUP ===
    PSSpecifier *controlGroup = [PSSpecifier groupSpecifierWithName:@"服务控制"];
    [specs addObject:controlGroup];

    PSSpecifier *startSpec = [PSSpecifier preferenceSpecifierNamed:@"启动 Frida 服务"
                                                           target:self
                                                              set:nil
                                                              get:nil
                                                           detail:nil
                                                             cell:PSButtonCell
                                                             edit:nil];
    startSpec->action = @selector(startServer);
    [specs addObject:startSpec];

    PSSpecifier *stopSpec = [PSSpecifier preferenceSpecifierNamed:@"停止 Frida 服务"
                                                          target:self
                                                             set:nil
                                                             get:nil
                                                          detail:nil
                                                            cell:PSButtonCell
                                                            edit:nil];
    stopSpec->action = @selector(stopServer);
    [specs addObject:stopSpec];

    PSSpecifier *restartSpec = [PSSpecifier preferenceSpecifierNamed:@"重启 Frida 服务"
                                                             target:self
                                                                set:nil
                                                                get:nil
                                                             detail:nil
                                                               cell:PSButtonCell
                                                               edit:nil];
    restartSpec->action = @selector(restartServer);
    [specs addObject:restartSpec];

    // === VERSION MANAGEMENT GROUP ===
    PSSpecifier *versionGroup = [PSSpecifier groupSpecifierWithName:@"版本管理"];
    [versionGroup setProperty:@"从 GitHub 下载并安装 frida-server，安装期间将停止服务。RootHide 下仍需验证服务端兼容性。" forKey:@"footerText"];
    [specs addObject:versionGroup];

    PSSpecifier *browseSpec = [PSSpecifier preferenceSpecifierNamed:@"浏览最新版本"
                                                            target:self
                                                               set:nil
                                                               get:nil
                                                            detail:[FMVersionListController class]
                                                              cell:PSLinkCell
                                                              edit:nil];
    [specs addObject:browseSpec];

    _customVersionSpecifier = [PSSpecifier preferenceSpecifierNamed:@"自定义版本"
                                                                   target:self
                                                                      set:@selector(setCustomVersion:specifier:)
                                                                      get:@selector(getCustomVersion:)
                                                                   detail:nil
                                                                     cell:PSEditTextCell
                                                                     edit:nil];
    [_customVersionSpecifier setProperty:@"customVersion" forKey:@"key"];
    [_customVersionSpecifier setProperty:@"例如 16.1.4" forKey:@"placeholder"];
    [specs addObject:_customVersionSpecifier];

    PSSpecifier *installCustomSpec = [PSSpecifier preferenceSpecifierNamed:@"安装指定版本"
                                                                   target:self
                                                                      set:nil
                                                                      get:nil
                                                                   detail:nil
                                                                     cell:PSButtonCell
                                                                     edit:nil];
    installCustomSpec->action = @selector(installCustomVersion);
    [specs addObject:installCustomSpec];

    // === MAINTENANCE GROUP ===
    PSSpecifier *maintGroup = [PSSpecifier groupSpecifierWithName:@"维护"];
    [specs addObject:maintGroup];

    PSSpecifier *historySpec = [PSSpecifier preferenceSpecifierNamed:@"下载历史"
                                                             target:self
                                                                set:nil
                                                                get:nil
                                                             detail:[FMDownloadHistoryController class]
                                                               cell:PSLinkCell
                                                               edit:nil];
    [specs addObject:historySpec];

    PSSpecifier *uninstallSpec = [PSSpecifier preferenceSpecifierNamed:@"卸载 Frida 服务端"
                                                               target:self
                                                                  set:nil
                                                                  get:nil
                                                               detail:nil
                                                                 cell:PSButtonCell
                                                                 edit:nil];
    uninstallSpec->action = @selector(uninstallServer);
    [specs addObject:uninstallSpec];

    PSSpecifier *logSpec = [PSSpecifier preferenceSpecifierNamed:@"查看日志"
                                                         target:self
                                                            set:nil
                                                            get:nil
                                                         detail:nil
                                                           cell:PSButtonCell
                                                           edit:nil];
    logSpec->action = @selector(viewLog);
    [specs addObject:logSpec];

    return specs;
}

#pragma mark - Status Getters

- (id)getStatusValue:(PSSpecifier *)specifier {
    NSDictionary *status = self.cachedStatus;
    if (!status) return @"管理守护进程离线";
    if ([status[@"stopping"] boolValue]) return @"正在停止…";
    BOOL installed = [status[@"installed"] boolValue];
    if (!installed) return @"未安装";
    BOOL running = [status[@"running"] boolValue];
    return running ? @"运行中" : @"已停止";
}

- (id)getPortStatusValue:(PSSpecifier *)specifier {
    NSDictionary *status = self.cachedStatus;
    if (!status) return @"\u2014";
    NSInteger port = [status[@"port"] integerValue];
    return port > 0 ? [NSString stringWithFormat:@"%ld", (long)port] : @"\u2014";
}

- (id)getBinaryPathValue:(PSSpecifier *)specifier {
    NSDictionary *status = self.cachedStatus;
    if (!status) return @"未知";
    NSString *path = status[@"binaryPath"];
    if (!path || [path isEqualToString:@"not found"]) return @"未找到";
    return path;
}

- (id)getVersionValue:(PSSpecifier *)specifier {
    NSDictionary *status = self.cachedStatus;
    if (!status) return @"未知";
    NSString *version = status[@"version"];
    if (!version || [version isEqualToString:@"unknown"]) return @"未知";
    return version;
}

- (id)getSourceValue:(PSSpecifier *)specifier {
    NSDictionary *status = self.cachedStatus;
    if (!status) return @"\u2014";
    NSString *source = status[@"source"];
    if (!source || [source isEqualToString:@"none"]) return @"\u2014";
    return [source isEqualToString:@"Package Manager"] ? @"软件包管理器" : ([source isEqualToString:@"FridaManager"] ? @"Frida 管理器" : source);
}

#pragma mark - Config Getters/Setters

- (id)getPortValue:(PSSpecifier *)specifier {
    NSDictionary *status = self.cachedStatus;
    NSDictionary *config = status[@"_config"];
    if (!config) return @"27042";
    return [NSString stringWithFormat:@"%ld", (long)[config[kFMConfigKeyPort] integerValue]];
}

- (void)setPortValue:(id)value specifier:(PSSpecifier *)specifier {
    NSInteger port = [value integerValue];
    if (port < 1 || port > 65535) return;
    NSString *cmd = [NSString stringWithFormat:@"%@:%ld", kFMCommandSetPort, (long)port];
    [[FMSocketClient sharedClient] sendCommand:cmd completion:^(NSString *response) {
        NSDictionary *status = self.cachedStatus;
        if (status && [status[@"running"] boolValue]) {
            [self promptRestartForPortChange];
        }
    }];
}

- (id)getLocalhostValue:(PSSpecifier *)specifier {
    NSDictionary *status = self.cachedStatus;
    NSDictionary *config = status[@"_config"];
    if (!config) return @(YES);
    return config[kFMConfigKeyLocalhostOnly] ?: @(YES);
}

- (void)setLocalhostValue:(id)value specifier:(PSSpecifier *)specifier {
    BOOL localhost = [value boolValue];
    NSString *cmd = [NSString stringWithFormat:@"%@:%d", kFMCommandSetLocalhost, localhost ? 1 : 0];
    [[FMSocketClient sharedClient] sendCommand:cmd completion:nil];
}

#pragma mark - Custom Version

- (id)getCustomVersion:(PSSpecifier *)specifier {
    return self.pendingCustomVersion ?: @"";
}

- (void)setCustomVersion:(id)value specifier:(PSSpecifier *)specifier {
    self.pendingCustomVersion = value;
}

#pragma mark - Actions

- (void)startServer {
    NSDictionary *status = self.cachedStatus;
    if (status && ![status[@"installed"] boolValue]) {
        [self showAlertWithTitle:@"未安装" message:@"未找到 frida-server 程序，请前往“版本管理”下载安装。"];
        return;
    }
    [[FMSocketClient sharedClient] sendCommand:kFMCommandStart completion:^(NSString *response) {
        if (![response hasPrefix:@"OK"]) {
            [self showAlertWithTitle:@"错误" message:response ?: @"连接管理守护进程失败"];
        }
        [self refreshStatusAsync];
    }];
}

- (void)stopServer {
    [[FMSocketClient sharedClient] sendCommand:kFMCommandStop completion:^(NSString *response) {
        if (![response hasPrefix:@"OK"]) {
            [self showAlertWithTitle:@"错误" message:response ?: @"连接管理守护进程失败"];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self refreshStatusAsync];
        });
    }];
}

- (void)restartServer {
    NSDictionary *status = self.cachedStatus;
    if (status && ![status[@"installed"] boolValue]) {
        [self showAlertWithTitle:@"未安装" message:@"未找到 frida-server 程序，请前往“版本管理”下载安装。"];
        return;
    }
    [[FMSocketClient sharedClient] sendCommand:kFMCommandRestart completion:^(NSString *response) {
        if (![response hasPrefix:@"OK"]) {
            [self showAlertWithTitle:@"错误" message:response ?: @"连接管理守护进程失败"];
        }
        [self refreshStatusAsync];
    }];
}

- (void)uninstallServer {
    NSDictionary *status = self.cachedStatus;
    if (status && ![status[@"installed"] boolValue]) {
        [self showAlertWithTitle:@"未安装" message:@"尚未安装 frida-server 程序。"];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"卸载 Frida 服务端"
                                                                  message:@"此操作将停止服务并删除由本管理器安装的 frida-server，确定继续吗？"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"卸载"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [[FMSocketClient sharedClient] sendCommand:kFMCommandUninstall completion:^(NSString *response) {
            if ([response hasPrefix:@"OK"]) {
                [self showAlertWithTitle:@"已卸载" message:@"frida-server 已移除。"];
            } else {
                [self showAlertWithTitle:@"错误" message:response ?: @"卸载失败"];
            }
            [self refreshStatusAsync];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewLog {
    [[FMSocketClient sharedClient] sendCommand:kFMCommandGetLog completion:^(NSString *response) {
        NSString *log = response ?: @"（无法读取日志）";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"管理守护进程日志"
                                                                      message:log
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)installCustomVersion {
    [self.view endEditing:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *version = self.pendingCustomVersion;
        if (!version || version.length == 0) {
            [self showAlertWithTitle:@"错误" message:@"请输入版本号（例如 16.1.4）。"];
            return;
        }
        [self confirmAndDownloadVersion:version];
    });
}

#pragma mark - Download Flow

- (void)confirmAndDownloadVersion:(NSString *)version {
    // Check if frida is installed via a package manager
    NSDictionary *status = self.cachedStatus;
    NSString *source = status[@"source"];
    if ([source isEqualToString:@"Package Manager"]) {
        [self showAlertWithTitle:@"无法安装"
                         message:@"当前 Frida 由软件包管理器（Sileo、Zebra、Cydia 等）安装。\n\n请先通过原软件包管理器卸载，再使用 Frida 管理器安装所需版本。"];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载 Frida 服务端"
                                                                  message:[NSString stringWithFormat:@"下载并安装 frida-server v%@？\n\n正在运行的服务将被停止。", version]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"下载"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self beginDownloadVersion:version];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginDownloadVersion:(NSString *)version {
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"正在下载…"
                                                                          message:[NSString stringWithFormat:@"正在安装 frida-server v%@\n\n请稍候…", version]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progressAlert animated:YES completion:nil];

    [[FMSocketClient sharedClient] sendCommand:kFMCommandStop completion:^(NSString *stopResp) {
        NSString *cmd = [NSString stringWithFormat:@"%@:%@", kFMCommandDownload, version];
        [[FMSocketClient sharedClient] sendCommand:cmd completion:^(NSString *response) {
            if (![response hasPrefix:@"OK"]) {
                NSString *errMsg = response ?: @"启动下载失败";
                if ([response containsString:@"PKGMGR"]) {
                    errMsg = @"Frida 由软件包管理器安装，请先通过原软件包管理器卸载。";
                }
                [progressAlert dismissViewControllerAnimated:YES completion:^{
                    [self showAlertWithTitle:@"错误" message:errMsg];
                }];
                return;
            }

            __block NSTimer *pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
                [[FMSocketClient sharedClient] sendCommand:kFMCommandDownloadProgress completion:^(NSString *resp) {
                    if (!resp) return;
                    NSData *data = [resp dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *progress = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (!progress) return;

                    BOOL downloading = [progress[@"downloading"] boolValue];
                    NSString *status = progress[@"status"];

                    progressAlert.message = [NSString stringWithFormat:@"正在安装 frida-server v%@\n\n%@", version, FMChineseText(status)];

                    if (!downloading) {
                        [pollTimer invalidate];
                        [progressAlert dismissViewControllerAnimated:YES completion:^{
                            if ([status hasPrefix:@"Installed"]) {
                                [self showAlertWithTitle:@"成功" message:[NSString stringWithFormat:@"frida-server v%@ 安装完成！", version]];
                            } else if (![status isEqualToString:@"Idle"]) {
                                [self showAlertWithTitle:@"失败" message:FMChineseText(status)];
                            }
                            [self refreshStatusAsync];
                        }];
                    }
                }];
            }];
        }];
    }];
}

#pragma mark - Async Status Refresh

- (void)refreshStatusAsync {
    [[FMSocketClient sharedClient] sendCommand:kFMCommandStatus completion:^(NSString *statusResp) {
        NSDictionary *status = nil;
        if (statusResp) {
            NSData *data = [statusResp dataUsingEncoding:NSUTF8StringEncoding];
            status = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }

        [[FMSocketClient sharedClient] sendCommand:kFMCommandGetConfig completion:^(NSString *configResp) {
            NSDictionary *config = nil;
            if (configResp) {
                NSData *data = [configResp dataUsingEncoding:NSUTF8StringEncoding];
                config = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }

            NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:status ?: @{}];
            if (config) merged[@"_config"] = config;
            self.cachedStatus = merged;

            [self reloadSpecifier:self->_statusSpecifier animated:NO];
            [self reloadSpecifier:self->_portStatusSpecifier animated:NO];
            [self reloadSpecifier:self->_binaryPathSpecifier animated:NO];
            [self reloadSpecifier:self->_versionSpecifier animated:NO];
            [self reloadSpecifier:self->_sourceSpecifier animated:NO];
        }];
    }];
}

#pragma mark - Helpers

- (void)promptRestartForPortChange {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"端口已更改"
                                                                  message:@"是否立即重启 frida-server 以使用新端口？"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"立即重启"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [[FMSocketClient sharedClient] sendCommand:kFMCommandRestart completion:^(NSString *resp) {
            [self refreshStatusAsync];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"稍后"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:FMChineseText(title)
                                                                  message:FMChineseText(message)
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - View Lifecycle

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshStatusAsync];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                   target:self
                                                 selector:@selector(refreshStatusAsync)
                                                 userInfo:nil
                                                  repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

@end

#pragma mark - Version List Controller

@interface FMVersionListController ()
@property (nonatomic, assign) BOOL hasStartedLoading;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) int pollCount;
@property (nonatomic, strong) NSMutableArray *currentSpecs;
@end

@implementation FMVersionListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"最新版本"];
        [group setProperty:@"正在从 GitHub 获取版本…" forKey:@"footerText"];
        [specs addObject:group];
        _specifiers = specs;

        if (!_hasStartedLoading) {
            _hasStartedLoading = YES;
            _pollCount = 0;
            // Delay to let the view finish loading first
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self fetchVersions];
            });
        }
    }
    return _specifiers;
}

- (void)fetchVersions {
    if (_isLoading) return;
    _isLoading = YES;

    [[FMSocketClient sharedClient] sendCommand:kFMCommandListVersions completion:^(NSString *response) {
        if (!response) {
            [self updateWithVersions:nil error:@"连接管理守护进程失败。"];
            return;
        }

        if ([response hasPrefix:@"WAIT"]) {
            self->_pollCount++;
            if (self->_pollCount < 15) {
                self->_isLoading = NO;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self fetchVersions];
                });
            } else {
                [self updateWithVersions:nil error:@"请求超时，请在“查看日志”中检查详情。"];
            }
            return;
        }

        if ([response hasPrefix:@"ERR"]) {
            [self updateWithVersions:nil error:response];
            return;
        }

        NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *versions = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([versions isKindOfClass:[NSArray class]] && versions.count > 0) {
            [self updateWithVersions:versions error:nil];
        } else {
            [self updateWithVersions:nil error:@"未找到版本，请在“查看日志”中检查详情。"];
        }
    }];
}

- (void)updateWithVersions:(NSArray *)versions error:(NSString *)error {
    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"最新版本"];

    if (versions && versions.count > 0) {
        [group setProperty:@"轻点版本即可下载并安装。" forKey:@"footerText"];
        [specs addObject:group];

        for (id item in versions) {
            NSString *version = nil;
            if ([item isKindOfClass:[NSString class]]) version = item;
            else if ([item isKindOfClass:[NSDictionary class]]) version = item[@"version"];
            if (!version) continue;

            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:version
                                                              target:self
                                                                 set:nil
                                                                 get:nil
                                                              detail:nil
                                                                cell:PSButtonCell
                                                                edit:nil];
            spec->action = @selector(versionTapped:);
            [spec setProperty:version forKey:@"versionTag"];
            [specs addObject:spec];
        }
    } else {
        [group setProperty:FMChineseText(error ?: @"获取版本列表失败。") forKey:@"footerText"];
        [specs addObject:group];

        PSSpecifier *retrySpec = [PSSpecifier preferenceSpecifierNamed:@"重试"
                                                               target:self
                                                                  set:nil
                                                                  get:nil
                                                               detail:nil
                                                                 cell:PSButtonCell
                                                                 edit:nil];
        retrySpec->action = @selector(retryFetch);
        [specs addObject:retrySpec];
    }

    _isLoading = NO;

    // Remove all existing specifiers one by one, then insert new ones
    // This avoids reloadSpecifiers which triggers the getter loop
    NSInteger oldCount = [self numberOfGroups] > 0 ? (NSInteger)_specifiers.count : 0;
    for (NSInteger i = oldCount - 1; i >= 0; i--) {
        [self removeSpecifierAtIndex:i animated:NO];
    }
    for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
        [self insertSpecifier:specs[i] atIndex:i animated:NO];
    }
}

- (void)retryFetch {
    _pollCount = 0;
    _isLoading = NO;
    _hasStartedLoading = NO;

    // Reset specifiers to loading state
    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"最新版本"];
    [group setProperty:@"正在从 GitHub 获取版本…" forKey:@"footerText"];
    [specs addObject:group];

    NSInteger oldCount = (NSInteger)_specifiers.count;
    for (NSInteger i = oldCount - 1; i >= 0; i--) {
        [self removeSpecifierAtIndex:i animated:NO];
    }
    for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
        [self insertSpecifier:specs[i] atIndex:i animated:NO];
    }

    _hasStartedLoading = YES;
    [self fetchVersions];
}

- (void)versionTapped:(PSSpecifier *)specifier {
    NSString *version = [specifier propertyForKey:@"versionTag"];
    if (!version) return;

    // First check source via a quick status query
    [[FMSocketClient sharedClient] sendCommand:kFMCommandStatus completion:^(NSString *resp) {
        NSDictionary *status = nil;
        if (resp) {
            NSData *data = [resp dataUsingEncoding:NSUTF8StringEncoding];
            status = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        NSString *source = status[@"source"];
        if ([source isEqualToString:@"Package Manager"]) {
            [self showAlertWithTitle:@"无法安装"
                             message:@"当前 Frida 由软件包管理器（Sileo、Zebra、Cydia 等）安装。\n\n请先通过原软件包管理器卸载，再使用 Frida 管理器安装所需版本。"];
            return;
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载 Frida 服务端"
                                                                      message:[NSString stringWithFormat:@"下载并安装 frida-server v%@？\n\n正在运行的服务将被停止。", version]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"下载"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [self beginDownloadVersion:version];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)beginDownloadVersion:(NSString *)version {
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"正在下载…"
                                                                          message:[NSString stringWithFormat:@"正在安装 frida-server v%@\n\n请稍候…", version]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progressAlert animated:YES completion:nil];

    [[FMSocketClient sharedClient] sendCommand:kFMCommandStop completion:^(NSString *stopResp) {
        NSString *cmd = [NSString stringWithFormat:@"%@:%@", kFMCommandDownload, version];
        [[FMSocketClient sharedClient] sendCommand:cmd completion:^(NSString *response) {
            if (![response hasPrefix:@"OK"]) {
                NSString *errMsg = response ?: @"启动下载失败";
                if ([response containsString:@"PKGMGR"]) {
                    errMsg = @"Frida 由软件包管理器安装，请先通过原软件包管理器卸载。";
                }
                [progressAlert dismissViewControllerAnimated:YES completion:^{
                    [self showAlertWithTitle:@"错误" message:errMsg];
                }];
                return;
            }

            __block NSTimer *pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
                [[FMSocketClient sharedClient] sendCommand:kFMCommandDownloadProgress completion:^(NSString *resp) {
                    if (!resp) return;
                    NSData *data = [resp dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *progress = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (!progress) return;

                    BOOL downloading = [progress[@"downloading"] boolValue];
                    NSString *status = progress[@"status"];

                    progressAlert.message = [NSString stringWithFormat:@"正在安装 frida-server v%@\n\n%@", version, FMChineseText(status)];

                    if (!downloading) {
                        [pollTimer invalidate];
                        [progressAlert dismissViewControllerAnimated:YES completion:^{
                            if ([status hasPrefix:@"Installed"]) {
                                [self showAlertWithTitle:@"成功" message:[NSString stringWithFormat:@"frida-server v%@ 安装完成！", version]];
                            } else if (![status isEqualToString:@"Idle"]) {
                                [self showAlertWithTitle:@"失败" message:FMChineseText(status)];
                            }
                        }];
                    }
                }];
            }];
        }];
    }];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:FMChineseText(title)
                                                                  message:FMChineseText(message)
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)title {
    return @"最新版本";
}

@end

#pragma mark - Download History Controller

@implementation FMDownloadHistoryController {
    BOOL _hasStartedLoading;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self buildEmptySpecifiers] mutableCopy];
        if (!_hasStartedLoading) {
            _hasStartedLoading = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self loadHistory];
            });
        }
    }
    return _specifiers;
}

- (NSArray *)buildEmptySpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"已下载版本"];
    [group setProperty:@"正在加载…" forKey:@"footerText"];
    [specs addObject:group];
    return specs;
}

- (void)loadHistory {
    [[FMSocketClient sharedClient] sendCommand:kFMCommandGetHistory completion:^(NSString *response) {
        NSArray *history = nil;
        if (response && ![response hasPrefix:@"ERR"]) {
            NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
            history = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateWithHistory:([history isKindOfClass:[NSArray class]] ? history : nil)];
        });
    }];
}

- (void)updateWithHistory:(NSArray *)history {
    // Remove all existing specifiers one by one
    NSInteger count = _specifiers.count;
    for (NSInteger i = count - 1; i >= 0; i--) {
        [self removeSpecifierAtIndex:i animated:NO];
    }

    NSInteger insertIdx = 0;

    if (history.count > 0) {
        PSSpecifier *histGroup = [PSSpecifier groupSpecifierWithName:@"已下载版本"];
        [histGroup setProperty:[NSString stringWithFormat:@"已下载 %lu 个版本。", (unsigned long)history.count] forKey:@"footerText"];
        [self insertSpecifier:histGroup atIndex:insertIdx++ animated:NO];

        for (NSDictionary *entry in history) {
            NSString *version = entry[@"version"] ?: @"?";
            NSString *date = entry[@"date"] ?: @"";

            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"v%@", version]
                                                              target:self
                                                                 set:nil
                                                                 get:@selector(getDateForEntry:)
                                                              detail:nil
                                                                cell:PSTitleValueCell
                                                                edit:nil];
            [spec setProperty:date forKey:@"entryDate"];
            [self insertSpecifier:spec atIndex:insertIdx++ animated:NO];
        }

        PSSpecifier *clearGroup = [PSSpecifier groupSpecifierWithName:nil];
        [self insertSpecifier:clearGroup atIndex:insertIdx++ animated:NO];

        PSSpecifier *clearSpec = [PSSpecifier preferenceSpecifierNamed:@"清空历史"
                                                               target:self
                                                                  set:nil
                                                                  get:nil
                                                               detail:nil
                                                                 cell:PSButtonCell
                                                                 edit:nil];
        clearSpec->action = @selector(clearHistory);
        [self insertSpecifier:clearSpec atIndex:insertIdx++ animated:NO];
    } else {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"已下载版本"];
        [group setProperty:@"暂无下载记录。" forKey:@"footerText"];
        [self insertSpecifier:group atIndex:insertIdx animated:NO];
    }
}

- (id)getDateForEntry:(PSSpecifier *)specifier {
    return [specifier propertyForKey:@"entryDate"] ?: @"";
}

- (void)clearHistory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空历史"
                                                                  message:@"确定清空所有下载历史记录吗？"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [[FMSocketClient sharedClient] sendCommand:kFMCommandClearHistory completion:^(NSString *response) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateWithHistory:nil];
            });
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)title {
    return @"下载历史";
}

@end
