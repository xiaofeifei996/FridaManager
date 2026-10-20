#ifndef FMCHINESE_H
#define FMCHINESE_H
#import <Foundation/Foundation.h>

// Translate only displayed text. Socket commands, JSON keys and state tokens
// stay unchanged so download completion and package-manager detection work.
static inline NSString *FMChineseText(NSString *text) {
    if (!text) return @"";
    static NSDictionary<NSString *, NSString *> *messages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        messages = @{
            @"Idle": @"空闲",
            @"Downloading .deb...": @"正在下载安装包…",
            @"Download failed": @"下载失败",
            @"Extracting...": @"正在解压…",
            @"Extraction failed": @"解压失败",
            @"Installing...": @"正在安装…",
            @"Extraction failed — frida-server not found": @"解压失败：未找到 frida-server",
            @"Install failed": @"安装失败",
            @"start failed": @"启动失败，请查看日志。",
            @"restart failed": @"重启失败，请查看日志。",
            @"stop in progress, please wait": @"正在停止服务，请稍候。",
            @"invalid port": @"端口无效，请输入 1–65535。",
            @"missing port value": @"缺少端口号。",
            @"missing value": @"缺少参数值。",
            @"missing version": @"缺少版本号。",
            @"unknown command": @"未知命令。",
            @"download in progress": @"已有下载任务正在进行。",
            @"error:failed to fetch versions": @"获取版本列表失败，请检查网络或查看日志。",
            @"failed to fetch versions": @"获取版本列表失败，请检查网络或查看日志。",
            @"PKGMGR": @"Frida 由软件包管理器安装，请先通过原软件包管理器卸载。",
            @"Frida was installed via a package manager. Use your package manager to remove it.": @"Frida 由软件包管理器安装，请通过原软件包管理器卸载。",
            @"no managed binary found": @"未找到由本管理器安装的服务端程序。",
            @"No log entries yet.": @"暂无日志记录。"
        };
    });
    NSString *payload = [text hasPrefix:@"ERR:"] ? [text substringFromIndex:4] : text;
    NSString *translated = messages[payload];
    if (translated) return translated;
    if ([payload hasPrefix:@"Installed v"]) {
        return [@"已安装 v" stringByAppendingString:[payload substringFromIndex:11]];
    }
    return payload;
}
#endif
