// Included by JPOriginalTitles.m so maintenance can reuse the existing cache and hooks.
#ifndef JPT_MANAGEMENT_TEST
#import <UIKit/UIKit.h>
#endif
#import <stdatomic.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <limits.h>

static NSString *const kJPTCacheVersion = @"6";
static NSString *const kJPTCacheVersionKey = @"JPOriginalTitlesCacheVersion";
static NSString *const kJPTLoggingKey = @"JPOriginalTitlesLoggingEnabled";
static NSString *const kJPTPendingResetKey = @"JPOriginalTitlesPendingReset";
static NSString *const kJPTLastResetKey = @"JPOriginalTitlesLastReset";
static NSString *const kJPTBuild = @"v6 · management 2026-10-11";
static const NSUInteger kJPTLogLimit = 1024 * 1024;
static atomic_bool gJPTLogging;
static BOOL gJPTManagementHookInstalled;

static dispatch_queue_t JPTLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("jpt.log", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *JPTLogPath(void) {
#ifdef JPT_MANAGEMENT_TEST
    return [[[NSProcessInfo processInfo] environment] objectForKey:@"JPT_TEST_LOG_PATH"];
#else
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"JPOriginalTitles.log"];
#endif
}

static NSData *JPTLogTail(NSString *path) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return nil;
    NSData *data = nil;
    @try {
        unsigned long long size = [file seekToEndOfFile];
        [file seekToFileOffset:size > kJPTLogLimit ? size - kJPTLogLimit : 0];
        data = [file readDataOfLength:kJPTLogLimit];
        if (size > kJPTLogLimit) {
            const uint8_t *bytes = data.bytes;
            NSUInteger start = 0;
            while (start < data.length && bytes[start] != '\n') start++;
            if (start < data.length) start++;
            data = [data subdataWithRange:NSMakeRange(start, data.length - start)];
        }
    } @catch (NSException *exception) {
        data = nil;
    } @finally { [file closeFile]; }
    return data;
}

static void JPTLog(NSString *format, ...) {
    if (!atomic_load(&gJPTLogging)) return;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (line.length > 2048) line = [[line substringToIndex:2048] stringByAppendingString:@" …"];
    NSData *data = [[NSString stringWithFormat:@"%@ %@\n", [NSDate date], line] dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(JPTLogQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = JPTLogPath();
        NSUInteger size = [[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedIntegerValue];
        if (size + data.length > kJPTLogLimit) {
            if (size > kJPTLogLimit && ![JPTLogTail(path) writeToFile:path atomically:YES]) return;
            NSString *previous = [path stringByAppendingString:@".1"];
            [fm removeItemAtPath:previous error:nil];
            if (![fm moveItemAtPath:path toPath:previous error:nil]) return;
        }
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!file) { [data writeToFile:path atomically:YES]; return; }
        @try {
            [file seekToEndOfFile];
            [file writeData:data];
        } @catch (NSException *exception) {
            // A diagnostic write must never interrupt the host app.
        } @finally { [file closeFile]; }
    });
}

static NSString *JPTScopeName(NSString *scope) {
    return [scope isEqualToString:@"metadata"] ? @"名称与曲库索引缓存" : @"插件名称缓存";
}

static NSString *JPTResetSummary(void) {
    NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTLastResetKey];
    if (!last) return @"尚无重置记录";
    NSString *state = [last[@"success"] boolValue] ? @"成功" : @"失败，可重试";
    return [NSString stringWithFormat:@"%@ · %@ · %@（删除 %@ 个数据库）", last[@"date"],
            JPTScopeName(last[@"scope"]), state, last[@"removed"] ?: @0];
}

#ifndef JPT_MANAGEMENT_TEST
static BOOL JPTDelegateHooked(NSString *name) {
    Class cls = NSClassFromString(name);
    return cls && [gDelegateClasses containsObject:cls];
}

static NSString *JPTDiagnosticSummary(void) {
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:@"JPOriginalTitles", kJPTBuild,
        [NSString stringWithFormat:@"Spotify %@ (%@)", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
         [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"],
        [NSString stringWithFormat:@"iOS %@", [UIDevice currentDevice].systemVersion],
        [NSString stringWithFormat:@"Settings hook: %@", gJPTManagementHookInstalled ? @"installed" : @"unavailable"], nil];
    for (NSString *name in @[@"SPTCoreURLSessionDataDelegate", @"Connectivity_HttpClientKit.HttpClientURLSession"]) {
        BOOL found = JPTDelegateHooked(name);
        [lines addObject:[NSString stringWithFormat:@"Delegate %@: %@", name, found ? @"hooked" : @"unavailable"]];
    }
    [lines addObject:[NSString stringWithFormat:@"Logging: %@", atomic_load(&gJPTLogging) ? @"on" : @"off"]];
    [lines addObject:[NSString stringWithFormat:@"Original cache: %lu; artist names: %lu", (unsigned long)JPTOriginalSnapshot().count,
                      (unsigned long)JPTArtistNamesSnapshot().count]];
    NSDictionary *pending = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTPendingResetKey];
    [lines addObject:[NSString stringWithFormat:@"Pending reset: %@", pending ? JPTScopeName(pending[@"scope"]) : @"none"]];
    [lines addObject:JPTResetSummary()];
    NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTLastResetKey];
    if (last[@"errors"]) [lines addObject:[NSString stringWithFormat:@"Reset errors: %@", last[@"errors"]]];
    return [lines componentsJoinedByString:@"\n"];
}
#endif

static NSString *JPTUsersPath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"PersistentCache/Users"];
}

// Inspect our own descriptors before any deletion, including LevelDB's LOCK/WAL files.
static BOOL JPTDatabaseIsOpen(void) {
    char path[PATH_MAX];
    for (int fd = 0, max = getdtablesize(); fd < max; fd++) {
        if (fcntl(fd, F_GETPATH, path) == 0 && strstr(path, "/primary.ldb/")) return YES;
    }
    return NO;
}

static BOOL JPTPlainDirectory(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode);
}

static void JPTProcessReset(NSString *users, NSUserDefaults *defaults) {
    NSMutableDictionary *pending = [[defaults dictionaryForKey:kJPTPendingResetKey] mutableCopy];
    BOOL migration = ![[defaults stringForKey:kJPTCacheVersionKey] isEqualToString:kJPTCacheVersion];
    NSDictionary *last = [defaults dictionaryForKey:kJPTLastResetKey];
    // Failed migrations wait for a user retry instead of wiping rebuilt databases on every launch.
    if (!pending && migration && ![last[@"migration"] isEqualToString:kJPTCacheVersion]) {
        pending = [@{@"scope": @"metadata", @"migration": kJPTCacheVersion} mutableCopy];
    }
    if (!pending || [pending[@"failed"] boolValue]) return;
    NSString *scope = pending[@"scope"];
    NSMutableArray *errors = [NSMutableArray array];
    NSMutableArray *remaining = [NSMutableArray array];
    NSUInteger removed = 0;
    NSArray *targets = nil;
    BOOL targetListKnown = NO;
    BOOL open = JPTDatabaseIsOpen();
    if ([scope isEqualToString:@"metadata"]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        targets = pending[@"remaining"];
        targetListKnown = targets != nil;
        if (!targets) {
            NSError *error = nil;
            NSArray *entries = [fm contentsOfDirectoryAtPath:users error:&error];
            targetListKnown = !error || error.code == NSFileReadNoSuchFileError;
            if (error && error.code != NSFileReadNoSuchFileError) {
                [errors addObject:[NSString stringWithFormat:@"enumeration %@/%ld", error.domain, (long)error.code]];
            }
            NSMutableArray *found = [NSMutableArray array];
            for (NSString *user in entries) {
                NSString *path = [[users stringByAppendingPathComponent:user] stringByAppendingPathComponent:@"primary.ldb"];
                if ([fm fileExistsAtPath:path]) [found addObject:user];
            }
            targets = found;
        }
        if (open) [errors addObject:@"database already open; deletion skipped"];
        for (NSString *user in targets) {
            // The stored retry list contains directory names only, never arbitrary paths.
            if (![user isKindOfClass:[NSString class]] || !user.length || ![user isEqualToString:user.lastPathComponent]
                || [user isEqualToString:@"."] || [user isEqualToString:@".."]) {
                [errors addObject:@"invalid retry target"]; continue;
            }
            NSString *dir = [users stringByAppendingPathComponent:user];
            NSString *db = [dir stringByAppendingPathComponent:@"primary.ldb"];
            if (![fm fileExistsAtPath:db]) continue;
            NSError *error = nil;
            BOOL safe = !open && JPTPlainDirectory(users) && JPTPlainDirectory(dir) && JPTPlainDirectory(db);
            if (safe && [fm removeItemAtPath:db error:&error]) removed++;
            else {
                [remaining addObject:user];
                [errors addObject:error ? [NSString stringWithFormat:@"deletion %@/%ld", error.domain, (long)error.code] : @"unsafe/open database; deletion skipped"];
            }
        }
    }
    [defaults removeObjectForKey:kJPTArtistNamesKey];
    BOOL ok = errors.count == 0;
    NSMutableDictionary *result = [@{@"scope": scope ?: @"plugin", @"date": [NSDate date].description,
        @"success": @(ok), @"removed": @(removed), @"databaseOpen": @(open), @"errors": errors} mutableCopy];
    if (pending[@"migration"]) result[@"migration"] = pending[@"migration"];
    [defaults setObject:result forKey:kJPTLastResetKey];
    if (ok) {
        [defaults removeObjectForKey:kJPTPendingResetKey];
        if ([scope isEqualToString:@"metadata"] && migration) [defaults setObject:kJPTCacheVersion forKey:kJPTCacheVersionKey];
    } else {
        pending[@"failed"] = @YES;
        // Re-enumerate only when enumeration itself failed; otherwise retry failed targets alone.
        if (targetListKnown) pending[@"remaining"] = remaining;
        [defaults setObject:pending forKey:kJPTPendingResetKey];
    }
    [defaults synchronize];
    JPTLog(@"startup reset %@: removed %lu, open %d, errors %lu", scope, (unsigned long)removed, open, (unsigned long)errors.count);
}

#ifndef JPT_MANAGEMENT_TEST
@interface JPTManagementController : UITableViewController
@end

@implementation JPTManagementController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"原文名称";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
        target:self action:@selector(refresh)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(close)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refresh { [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 4 : section == 1 ? 3 : 4; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"状态", @"诊断", @"缓存维护"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"诊断默认关闭。日志可能包含曲目名称与 URI，不记录认证令牌或完整响应。日志最多保留两份，每份 1 MB。";
    if (section == 2) return @"重置在完全关闭后重新启动 Spotify 时执行。仅重置插件缓存不会刷新 Spotify 已存的名称；名称与曲库索引重置需要联网重新同步。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *pending = [defaults dictionaryForKey:kJPTPendingResetKey];
    if (index.section == 0) {
        cell.textLabel.text = @[@"版本", @"网络 hook", @"插件缓存", @"上次重置"][index.row];
        if (index.row == 0) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · Spotify %@", kJPTBuild,
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"];
        if (index.row == 1) cell.detailTextLabel.text = [NSString stringWithFormat:@"Core %@ · HttpClient %@",
            JPTDelegateHooked(@"SPTCoreURLSessionDataDelegate") ? @"已安装" : @"不可用",
            JPTDelegateHooked(@"Connectivity_HttpClientKit.HttpClientURLSession") ? @"已安装" : @"不可用"];
        if (index.row == 2) cell.detailTextLabel.text = [NSString stringWithFormat:@"原文曲目 %lu · 艺人映射 %lu",
            (unsigned long)JPTOriginalSnapshot().count, (unsigned long)JPTArtistNamesSnapshot().count];
        if (index.row == 3) cell.detailTextLabel.text = JPTResetSummary();
    } else if (index.section == 1) {
        cell.textLabel.text = @[@"诊断日志", @"导出诊断", @"清空日志"][index.row];
        if (index.row == 0) {
            cell.accessibilityIdentifier = @"jpt.logging";
            UISwitch *toggle = [UISwitch new];
            toggle.on = atomic_load(&gJPTLogging);
            toggle.accessibilityIdentifier = @"jpt.logging";
            [toggle addTarget:self action:@selector(loggingChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        } else cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = @[@"重置插件名称缓存", @"重置名称与曲库索引缓存", @"待执行重置", @"取消待执行重置"][index.row];
        if (index.row == 2) {
            cell.detailTextLabel.text = pending ? [NSString stringWithFormat:@"%@ · %@", JPTScopeName(pending[@"scope"]),
                [pending[@"failed"] boolValue] ? @"失败，点此预约重试" : @"下次启动执行"] : @"无";
            if ([pending[@"failed"] boolValue]) cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            if (index.row == 3 && !pending) cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
    }
    return cell;
}
- (void)message:(NSString *)title body:(NSString *)body {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)loggingChanged:(UISwitch *)toggle {
    [[NSUserDefaults standardUserDefaults] setBool:toggle.on forKey:kJPTLoggingKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    atomic_store(&gJPTLogging, toggle.on);
    if (toggle.on) JPTLog(@"diagnostics enabled\n%@", JPTDiagnosticSummary());
}
- (void)schedule:(NSString *)scope retry:(BOOL)retry {
    NSString *body = [scope isEqualToString:@"metadata"]
        ? @"下次启动清除名称元数据与曲库索引，并重置插件缓存。登录、设置和音频文件保留；需要联网重新同步，蓝牙引导可能重现，离线未同步改动可能丢失。清理后已下载歌曲的离线播放尚未验证。"
        : @"下次启动清除插件的原文曲目与艺人映射。Spotify 已存的名称不会被清除，映射会逐步重新学习。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:retry ? @"重试缓存重置" : @"预约缓存重置"
        message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"下次启动重置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *pending = retry ? [[defaults dictionaryForKey:kJPTPendingResetKey] mutableCopy] : [NSMutableDictionary dictionary];
        pending[@"scope"] = scope;
        [pending removeObjectForKey:@"failed"];
        [defaults setObject:pending forKey:kJPTPendingResetKey];
        [defaults synchronize];
        JPTLog(@"reset scheduled: %@", scope);
        [self refresh];
        [self message:@"已预约" body:@"请完全关闭后重新打开 Spotify。进入后台不会执行重置；重启前可以取消预约。"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)exportFrom:(UITableViewCell *)cell {
    NSString *summary = JPTDiagnosticSummary();
    dispatch_async(JPTLogQueue(), ^{
        NSString *path = JPTLogPath();
        NSMutableString *text = [[summary stringByAppendingString:@"\n\nLogs may contain listening information.\n"] mutableCopy];
        for (NSString *file in @[[path stringByAppendingString:@".1"], path]) {
            NSData *data = JPTLogTail(file);
            NSString *log = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            if (log.length) [text appendFormat:@"\n--- %@ ---\n%@", file.lastPathComponent, log];
        }
        if ([text rangeOfString:@"--- JPOriginalTitles.log"].location == NSNotFound) [text appendString:@"\nNo recorded logs. Enable diagnostics and reproduce the issue first.\n"];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"jpt-diagnostics-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"JPOriginalTitles-diagnostics.txt"]];
        BOOL ok = !error && [text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) { [[NSFileManager defaultManager] removeItemAtPath:dir error:nil]; [self message:@"导出失败" body:@"无法写入诊断文件，请重试。"]; return; }
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            share.popoverPresentationController.sourceView = cell;
            share.popoverPresentationController.sourceRect = cell.bounds;
            share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *shareError) {
                [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
            };
            [self presentViewController:share animated:YES completion:nil];
        });
    });
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *pending = [defaults dictionaryForKey:kJPTPendingResetKey];
    if (index.section == 1 && index.row == 1) [self exportFrom:[tableView cellForRowAtIndexPath:index]];
    if (index.section == 1 && index.row == 2) {
        dispatch_async(JPTLogQueue(), ^{
            [[NSFileManager defaultManager] removeItemAtPath:JPTLogPath() error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:[JPTLogPath() stringByAppendingString:@".1"] error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self message:@"日志已清空" body:@"诊断开关保持原状态，后续日志会继续按该状态记录。"]; });
        });
    }
    if (index.section == 2 && index.row < 2) [self schedule:index.row == 1 ? @"metadata" : @"plugin" retry:NO];
    if (index.section == 2 && index.row == 2 && [pending[@"failed"] boolValue]) [self schedule:pending[@"scope"] retry:YES];
    if (index.section == 2 && index.row == 3 && pending) {
        [defaults removeObjectForKey:kJPTPendingResetKey];
        [defaults synchronize];
        JPTLog(@"pending reset cancelled");
        [self refresh];
    }
}
@end

@interface JPTManagementEntry : NSObject
@property (nonatomic, weak) UIViewController *host;
- (void)open;
@end
@implementation JPTManagementEntry
- (void)open {
    if (!self.host || self.host.presentedViewController) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[JPTManagementController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor labelColor]};
    nav.navigationBar.standardAppearance = appearance;
    nav.navigationBar.scrollEdgeAppearance = appearance;
    nav.navigationBar.compactAppearance = appearance;
    nav.navigationBar.tintColor = [UIColor labelColor];
    [self.host presentViewController:nav animated:YES completion:nil];
}
@end

static char kJPTEntryKey;
static void JPTInstallManagementHook(void) {
    Class cls = NSClassFromString(@"_TtC21Settings_PlatformImpl26SettingsListViewController");
    SEL selector = @selector(viewDidAppear:);
    Method method = cls ? JPTOwnMethod(cls, selector) : NULL;
    if (!method) { JPTLog(@"settings hook unavailable"); return; }
    typedef void (*Fn)(id, SEL, BOOL);
    Fn original = (Fn)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^(UIViewController *host, BOOL animated) {
        original(host, selector, animated);
        JPTManagementEntry *entry = objc_getAssociatedObject(host, &kJPTEntryKey);
        if (!entry) {
            entry = [JPTManagementEntry new]; entry.host = host;
            objc_setAssociatedObject(host, &kJPTEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSMutableArray *items = [host.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
        for (UIBarButtonItem *item in items) if (item.target == entry) return;
        UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"原文" style:UIBarButtonItemStylePlain target:entry action:@selector(open)];
        button.accessibilityLabel = @"原文名称管理";
        button.accessibilityIdentifier = @"jpt.management";
        [items addObject:button];
        host.navigationItem.rightBarButtonItems = items;
        JPTLog(@"settings entry added");
    }));
    gJPTManagementHookInstalled = YES;
    JPTLog(@"settings hook installed");
}

__attribute__((constructor)) static void JPTInit(void) {
    @autoreleasepool {
        atomic_store(&gJPTLogging, [[NSUserDefaults standardUserDefaults] boolForKey:kJPTLoggingKey]);
        JPTProcessReset(JPTUsersPath(), [NSUserDefaults standardUserDefaults]);
        JPTInitializeNetwork();
        JPTInstallManagementHook();
    }
}
#endif
