// Included by JPOriginalTitles.m so maintenance can reuse the existing cache and hooks.
#ifndef JPT_MANAGEMENT_TEST
#import <UIKit/UIKit.h>
#endif
#import <stdatomic.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <limits.h>

static NSString *const kJPTCacheVersion = @"6.1";
static NSString *const kJPTCacheVersionKey = @"JPOriginalTitlesCacheVersion";
static NSString *const kJPTLoggingKey = @"JPOriginalTitlesLoggingEnabled";
static NSString *const kJPTPendingResetKey = @"JPOriginalTitlesPendingReset";
static NSString *const kJPTLastResetKey = @"JPOriginalTitlesLastReset";
static NSString *const kJPTBuild = @"v6.1";
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
    return [scope isEqualToString:@"metadata"] ? @"Spotify metadata and library index" : @"Plugin name cache";
}

static NSString *JPTResetSummary(void) {
    NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTLastResetKey];
    if (!last) return @"No reset recorded";
    NSString *state = [last[@"success"] boolValue] ? @"Succeeded" : @"Failed; retry available";
    return [NSString stringWithFormat:@"%@ · %@ · %@ (%@ databases removed)", last[@"date"],
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
    if (last[@"targets"]) [lines addObject:[NSString stringWithFormat:@"Startup database targets: %@; user directory exists: %@; database open: %@", last[@"targets"], last[@"usersExist"], last[@"databaseOpen"]]];
    [lines addObject:[NSString stringWithFormat:@"Cache version: %@", [[NSUserDefaults standardUserDefaults] stringForKey:kJPTCacheVersionKey] ?: @"unset"]];
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
    result[@"targets"] = @(targets.count);
    result[@"usersExist"] = @([[NSFileManager defaultManager] fileExistsAtPath:users]);
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

// Persist before quitting; retries retain only the targets that previously failed.
static BOOL JPTSavePendingReset(NSUserDefaults *defaults, NSString *scope, BOOL retry) {
    NSMutableDictionary *pending = retry ? [[defaults dictionaryForKey:kJPTPendingResetKey] mutableCopy] : [NSMutableDictionary dictionary];
    if (!pending) return NO;
    pending[@"scope"] = scope;
    [pending removeObjectForKey:@"failed"];
    [defaults setObject:pending forKey:kJPTPendingResetKey];
    return [defaults synchronize];
}

#ifndef JPT_MANAGEMENT_TEST
@interface JPTManagementController : UITableViewController
@property (nonatomic) BOOL resetPlugin;
@property (nonatomic) BOOL resetMetadata;
@property (nonatomic) BOOL retryFailed;
@end

@implementation JPTManagementController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Original Titles";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Apply" style:UIBarButtonItemStyleDone target:self action:@selector(apply)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"jpt.apply";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refresh {
    self.navigationItem.rightBarButtonItem.enabled = self.resetPlugin || self.resetMetadata || self.retryFailed;
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 4 : section == 1 ? 3 : 5; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @[@"Status", @"Diagnostics", @"Reset Options"][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"Logging is off by default. Logs may include track names and URIs. No authentication tokens or full responses are recorded. Two log files are retained, up to 1 MB each.";
    if (section == 2) return @"Select reset options, then tap Apply. Apply saves the request and closes the app immediately. Reopen Spotify to complete the reset. Metadata reset requires online resync and may discard unsynced offline changes. Login, settings and audio files are kept; downloaded offline playback after reset is unverified.";
    return nil;
}
- (void)checkbox:(UITableViewCell *)cell selected:(BOOL)selected identifier:(NSString *)identifier {
    UIImageView *box = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:selected ? @"checkmark.square.fill" : @"square"]];
    box.tintColor = selected ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    box.frame = CGRectMake(0, 0, 24, 24);
    cell.accessoryView = box;
    cell.accessibilityIdentifier = identifier;
    cell.accessibilityValue = selected ? @"Selected" : @"Not selected";
    if (selected) cell.accessibilityTraits |= UIAccessibilityTraitSelected;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *pending = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTPendingResetKey];
    if (index.section == 0) {
        cell.textLabel.text = @[@"Version", @"Network Hooks", @"Plugin Cache", @"Last Reset"][index.row];
        if (index.row == 0) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · Spotify %@", kJPTBuild, [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"];
        if (index.row == 1) cell.detailTextLabel.text = [NSString stringWithFormat:@"Core %@ · HttpClient %@", JPTDelegateHooked(@"SPTCoreURLSessionDataDelegate") ? @"installed" : @"unavailable", JPTDelegateHooked(@"Connectivity_HttpClientKit.HttpClientURLSession") ? @"installed" : @"unavailable"];
        if (index.row == 2) cell.detailTextLabel.text = [NSString stringWithFormat:@"Original tracks %lu · Artist names %lu", (unsigned long)JPTOriginalSnapshot().count, (unsigned long)JPTArtistNamesSnapshot().count];
        if (index.row == 3) cell.detailTextLabel.text = JPTResetSummary();
    } else if (index.section == 1) {
        cell.textLabel.text = @[@"Diagnostic Logging", @"Export Diagnostics", @"Clear Logs"][index.row];
        if (index.row == 0) {
            cell.accessibilityIdentifier = @"jpt.logging";
            UISwitch *toggle = [UISwitch new]; toggle.on = atomic_load(&gJPTLogging); toggle.accessibilityIdentifier = @"jpt.logging";
            [toggle addTarget:self action:@selector(loggingChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
        } else cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = @[@"Reset Plugin Name Cache", @"Reset Spotify Metadata and Library Index", @"Retry Failed Reset", @"Pending Reset", @"Cancel Pending Reset"][index.row];
        if (index.row == 0) {
            cell.detailTextLabel.text = @"Clear original-track lookups and learned artist names.";
            [self checkbox:cell selected:self.resetPlugin identifier:@"jpt.reset.plugin"];
        } else if (index.row == 1) {
            cell.detailTextLabel.text = @"Also reset the plugin cache. Spotify must resync online.";
            [self checkbox:cell selected:self.resetMetadata identifier:@"jpt.reset.metadata"];
        } else if (index.row == 2) {
            if ([pending[@"failed"] boolValue]) {
                cell.detailTextLabel.text = JPTScopeName(pending[@"scope"]);
                [self checkbox:cell selected:self.retryFailed identifier:@"jpt.reset.retry"];
            } else { cell.detailTextLabel.text = @"No failed reset"; cell.textLabel.textColor = [UIColor secondaryLabelColor]; }
        } else if (index.row == 3) {
            cell.detailTextLabel.text = pending ? [NSString stringWithFormat:@"%@ · %@", JPTScopeName(pending[@"scope"]), [pending[@"failed"] boolValue] ? @"Failed" : @"On next launch"] : @"None";
        } else {
            cell.selectionStyle = pending ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
            if (!pending) cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
    }
    return cell;
}
- (void)message:(NSString *)title body:(NSString *)body {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)loggingChanged:(UISwitch *)toggle {
    [[NSUserDefaults standardUserDefaults] setBool:toggle.on forKey:kJPTLoggingKey];
    [[NSUserDefaults standardUserDefaults] synchronize]; atomic_store(&gJPTLogging, toggle.on);
    if (toggle.on) JPTLog(@"diagnostics enabled\n%@", JPTDiagnosticSummary());
}
- (void)apply {
    if (!self.resetPlugin && !self.resetMetadata && !self.retryFailed) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *scope = self.retryFailed ? [defaults dictionaryForKey:kJPTPendingResetKey][@"scope"] : self.resetMetadata ? @"metadata" : @"plugin";
    if (!JPTSavePendingReset(defaults, scope, self.retryFailed)) {
        [self message:@"Apply Failed" body:@"The reset request could not be saved. The app will stay open; please retry."]; return;
    }
    JPTLog(@"Apply: reset %@ saved; quitting", scope);
    dispatch_sync(JPTLogQueue(), ^{});
    exit(EXIT_SUCCESS);
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
            if (!ok) { [[NSFileManager defaultManager] removeItemAtPath:dir error:nil]; [self message:@"Export Failed" body:@"Unable to write the diagnostic file. Please retry."]; return; }
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            share.popoverPresentationController.sourceView = cell; share.popoverPresentationController.sourceRect = cell.bounds;
            share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *shareError) { [[NSFileManager defaultManager] removeItemAtPath:dir error:nil]; };
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
            dispatch_async(dispatch_get_main_queue(), ^{ [self message:@"Logs Cleared" body:@"The diagnostic logging setting is unchanged."]; });
        });
    }
    if (index.section != 2) return;
    if (index.row == 0) { self.retryFailed = NO; self.resetPlugin = !self.resetPlugin; if (!self.resetPlugin) self.resetMetadata = NO; }
    if (index.row == 1) { self.retryFailed = NO; self.resetMetadata = !self.resetMetadata; if (self.resetMetadata) self.resetPlugin = YES; }
    if (index.row == 2 && [pending[@"failed"] boolValue]) { self.retryFailed = !self.retryFailed; self.resetPlugin = NO; self.resetMetadata = NO; }
    if (index.row == 4 && pending) { [defaults removeObjectForKey:kJPTPendingResetKey]; [defaults synchronize]; self.retryFailed = NO; JPTLog(@"pending reset cancelled"); }
    [self refresh];
}
@end

@interface JPTManagementEntry : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIBarButtonItem *gear;
@property (nonatomic, weak) UIButton *eeveeRow;
@property (nonatomic, weak) UIButton *titleRow;
- (void)open;
- (void)openEevee;
@end
@implementation JPTManagementEntry
- (void)openEevee {
    UIControl *control = [self.gear.customView isKindOfClass:[UIControl class]] ? (UIControl *)self.gear.customView : nil;
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}
- (void)open {
    if (!self.host || self.host.presentedViewController) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[JPTManagementController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground]; appearance.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor labelColor]};
    nav.navigationBar.standardAppearance = appearance; nav.navigationBar.scrollEdgeAppearance = appearance; nav.navigationBar.compactAppearance = appearance;
    nav.navigationBar.tintColor = [UIColor labelColor];
    [self.host presentViewController:nav animated:YES completion:nil];
}
@end

static char kJPTEntryKey;
static UICollectionView *JPTSettingsCollection(UIView *view) {
    if ([view isKindOfClass:[UICollectionView class]]) return (UICollectionView *)view;
    for (UIView *child in view.subviews) { UICollectionView *found = JPTSettingsCollection(child); if (found) return found; }
    return nil;
}
static UIButton *JPTSettingsRow(NSString *title, NSString *identifier, JPTManagementEntry *entry, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 42);
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    [button setTitle:title forState:UIControlStateNormal]; [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier; button.accessibilityLabel = title;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [button addTarget:entry action:action forControlEvents:UIControlEventTouchUpInside];
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    arrow.tag = 0x4a5054;
    arrow.tintColor = [UIColor secondaryLabelColor]; arrow.frame = CGRectMake(0, 26, 12, 16);
    arrow.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [button addSubview:arrow];
    return button;
}
static void JPTInsertManagementEntry(UIViewController *host) {
    UICollectionView *collection = JPTSettingsCollection(host.view);
    if (!collection || collection.bounds.size.width <= 0) return;
    JPTManagementEntry *entry = objc_getAssociatedObject(collection, &kJPTEntryKey);
    CGFloat height = 68;
    if (!entry) {
        UIBarButtonItem *gear = nil;
        for (UIBarButtonItem *item in host.navigationItem.rightBarButtonItems) if (item.tag == 1337) { gear = item; break; }
        UIView *existing = [collection viewWithTag:1338];
        if (!existing && ![gear.customView isKindOfClass:[UIControl class]]) return;
        entry = [JPTManagementEntry new]; entry.host = host; entry.gear = gear;
        objc_setAssociatedObject(collection, &kJPTEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIButton *eevee = (UIButton *)existing;
        if (!eevee) { eevee = JPTSettingsRow(@"Eevee Settings", @"jpt.eevee", entry, @selector(openEevee)); [collection addSubview:eevee]; }
        entry.eeveeRow = eevee;
        UIButton *titles = JPTSettingsRow(@"Original Titles", @"jpt.management", entry, @selector(open));
        [collection addSubview:titles]; entry.titleRow = titles;
        // Reserve only our additional rows, once per collection-view instance.
        CGFloat added = existing ? height : height * 2;
        UIEdgeInsets inset = collection.contentInset; inset.top += added; collection.contentInset = inset;
        UIEdgeInsets indicators = collection.verticalScrollIndicatorInsets; indicators.top += added; collection.verticalScrollIndicatorInsets = indicators;
        CGPoint offset = collection.contentOffset; offset.y -= added; [collection setContentOffset:offset animated:NO];
        JPTLog(@"inline settings entries installed; existing Eevee row %d, gear %d", existing != nil, gear != nil);
    }
    entry.host = host;
    entry.eeveeRow.frame = CGRectMake(0, -height * 2, collection.bounds.size.width, height);
    entry.titleRow.frame = CGRectMake(0, -height, collection.bounds.size.width, height);
    UIView *eeveeArrow = [entry.eeveeRow viewWithTag:0x4a5054];
    UIView *titleArrow = [entry.titleRow viewWithTag:0x4a5054];
    eeveeArrow.frame = CGRectMake(collection.bounds.size.width - 28, 26, 12, 16);
    titleArrow.frame = CGRectMake(collection.bounds.size.width - 28, 26, 12, 16);
}
static void JPTInstallManagementHook(void) {
    Class cls = NSClassFromString(@"_TtC21Settings_PlatformImpl26SettingsListViewController");
    SEL selector = NSSelectorFromString(@"viewDidAppear:");
    Method method = cls ? JPTOwnMethod(cls, selector) : NULL;
    if (method) {
        IMP original = method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(UIViewController *host, BOOL animated) {
            ((void (*)(id, SEL, BOOL))original)(host, selector, animated);
            UICollectionView *collection = JPTSettingsCollection(host.view);
            BOOL inserted = collection && !objc_getAssociatedObject(collection, &kJPTEntryKey);
            JPTInsertManagementEntry(host);
            if (inserted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    JPTInsertManagementEntry(host);
                    UICollectionView *current = JPTSettingsCollection(host.view);
                    if (objc_getAssociatedObject(current, &kJPTEntryKey))
                        [current setContentOffset:CGPointMake(current.contentOffset.x, -current.adjustedContentInset.top) animated:NO];
                });
            }
        }));
        gJPTManagementHookInstalled = YES;
    }
    JPTLog(@"settings hook %@", gJPTManagementHookInstalled ? @"installed" : @"unavailable");
}

__attribute__((constructor)) static void JPTInit(void) {
    @autoreleasepool {
        atomic_store(&gJPTLogging, [[NSUserDefaults standardUserDefaults] boolForKey:kJPTLoggingKey]);
        JPTProcessReset(JPTUsersPath(), [NSUserDefaults standardUserDefaults]);
        JPTInitializeNetwork(); JPTInstallManagementHook();
    }
}
#endif
