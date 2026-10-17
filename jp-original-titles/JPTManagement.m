// Included by JPOriginalTitles.m so maintenance can reuse the existing cache and hooks.
#ifndef JPT_MANAGEMENT_TEST
#import <UIKit/UIKit.h>
#endif
#import <stdatomic.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <limits.h>

static NSString *const kJPTCacheVersion = @"6.3";
static NSString *const kJPTCacheVersionKey = @"JPOriginalTitlesCacheVersion";
static NSString *const kJPTLoggingKey = @"JPOriginalTitlesLoggingEnabled";
static NSString *const kJPTPendingResetKey = @"JPOriginalTitlesPendingReset";
static NSString *const kJPTLastResetKey = @"JPOriginalTitlesLastReset";
static NSString *const kJPTMetadataPromptKey = @"JPOriginalTitlesMetadataPromptOffered";
static NSString *const kJPTBuild = @"v7";
static NSString *const kJPTBuildID = @"20261016-previous-metadata-no-eviction";
static const NSUInteger kJPTLogLimit = 1024 * 1024;
static atomic_bool gJPTLogging;
static atomic_bool gJPTStrict;
static NSString *const kJPTStrictKey = @"JPOriginalTitlesStrictMode";
static BOOL JPTStrictMode(void) { return atomic_load(&gJPTStrict); }
static void JPTLoadStrictMode(NSUserDefaults *defaults) { atomic_store(&gJPTStrict, [defaults boolForKey:kJPTStrictKey]); }
static void JPTSetStrictMode(NSUserDefaults *defaults, BOOL enabled) {
    [defaults setBool:enabled forKey:kJPTStrictKey]; [defaults synchronize]; atomic_store(&gJPTStrict, enabled);
}
static NSString *JPTStrictSummary(void) { return [NSString stringWithFormat:@"Strict mode: %@", JPTStrictMode() ? @"on" : @"off"]; }
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
    if ([scope isEqualToString:@"metadata"]) return @"Spotify metadata and library index";
    if ([scope isEqualToString:@"playback"]) return @"Playback resume state";
    return @"Plugin name cache";
}

static NSString *JPTSelectionName(NSDictionary *reset) {
    NSString *name = JPTScopeName(reset[@"scope"]);
    return [reset[@"playback"] boolValue] && ![reset[@"scope"] isEqualToString:@"playback"]
        ? [name stringByAppendingString:@" + Playback resume state"] : name;
}

static NSString *JPTResetSummary(void) {
    NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTLastResetKey];
    if (!last) return @"No reset recorded";
    NSString *state = [last[@"success"] boolValue] ? @"Succeeded" : @"Failed; retry available";
    return [NSString stringWithFormat:@"%@ · %@ · %@ (%@ databases, %@ playback states removed)", last[@"date"],
            JPTSelectionName(last), state, last[@"removed"] ?: @0, last[@"playbackRemoved"] ?: @0];
}

#ifndef JPT_MANAGEMENT_TEST
static BOOL JPTDelegateHooked(NSString *name) {
    Class cls = NSClassFromString(name);
    return cls && [gDelegateClasses containsObject:cls];
}

static NSString *JPTUsersPath(void);
static BOOL JPTDatabaseIsOpen(void);

static NSString *JPTDiagnosticSummary(void) {
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:@"JPOriginalTitles", kJPTBuild,
        [@"Build: " stringByAppendingString:kJPTBuildID],
        [NSString stringWithFormat:@"Spotify %@ (%@)", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
         [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"],
        [NSString stringWithFormat:@"iOS %@", [UIDevice currentDevice].systemVersion],
        [NSString stringWithFormat:@"Settings hook: %@", gJPTManagementHookInstalled ? @"installed" : @"unavailable"], nil];
    for (NSString *name in @[@"SPTCoreURLSessionDataDelegate", @"Connectivity_HttpClientKit.HttpClientURLSession"]) {
        BOOL found = JPTDelegateHooked(name);
        [lines addObject:[NSString stringWithFormat:@"Delegate %@: %@", name, found ? @"hooked" : @"unavailable"]];
    }
    [lines addObject:JPTStrictSummary()];
    [lines addObject:[NSString stringWithFormat:@"Logging: %@", atomic_load(&gJPTLogging) ? @"on" : @"off"]];
    [lines addObject:[NSString stringWithFormat:@"Original cache: %lu; artist names: %lu", (unsigned long)JPTOriginalSnapshot().count,
                      (unsigned long)JPTArtistNamesSnapshot().count]];
    [lines addObject:[NSString stringWithFormat:@"Previous metadata records: %lu", (unsigned long)JPTPreviousRecordCount()]];
    NSString *users = JPTUsersPath();
    [lines addObject:[@"Metadata directory: " stringByAppendingString:users ?: @"unavailable"]];
    [lines addObject:[@"Foundation home: " stringByAppendingString:NSHomeDirectory() ?: @"unavailable"]];
    for (NSString *key in @[@"HOME", @"CFFIXED_USER_HOME", @"LC_HOME_PATH"]) {
        const char *value = getenv(key.UTF8String);
        if (value) [lines addObject:[NSString stringWithFormat:@"Environment %@: %s", key, value]];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger count = 0;
    for (NSString *user in [fm contentsOfDirectoryAtPath:users error:nil])
        if ([fm fileExistsAtPath:[[users stringByAppendingPathComponent:user] stringByAppendingPathComponent:@"primary.ldb"]]) count++;
    [lines addObject:[NSString stringWithFormat:@"Current databases: %lu; database open: %@", (unsigned long)count, JPTDatabaseIsOpen() ? @"yes" : @"no"]];
    NSDictionary *pending = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kJPTPendingResetKey];
    [lines addObject:[NSString stringWithFormat:@"Pending reset: %@", pending ? JPTSelectionName(pending) : @"none"]];
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

// Inspect only the selected files before deleting them during startup.
static BOOL JPTResetFilesAreOpen(BOOL metadata, BOOL playback) {
    char path[PATH_MAX];
    for (int fd = 0, max = getdtablesize(); fd < max; fd++) {
        if (fcntl(fd, F_GETPATH, path) == 0
            && ((metadata && strstr(path, "/primary.ldb/"))
                || (playback && strstr(path, "/context_player_state_restore")))) return YES;
    }
    return NO;
}

static BOOL JPTDatabaseIsOpen(void) { return JPTResetFilesAreOpen(YES, NO); }

static BOOL JPTPlainDirectory(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode);
}

static void JPTProcessReset(NSString *users, NSUserDefaults *defaults) {
    NSMutableDictionary *pending = [[defaults dictionaryForKey:kJPTPendingResetKey] mutableCopy];
    BOOL migration = ![[defaults stringForKey:kJPTCacheVersionKey] isEqualToString:kJPTCacheVersion];
    NSDictionary *last = [defaults dictionaryForKey:kJPTLastResetKey];
    // Automatic upgrades reset plugin state only; Spotify caches require an explicit selection.
    if (!pending && migration && ![last[@"migration"] isEqualToString:kJPTCacheVersion]) {
        pending = [@{@"scope": @"plugin", @"migration": kJPTCacheVersion} mutableCopy];
    }
    if (pending[@"migration"]) {
        pending = [@{@"scope": @"plugin", @"migration": kJPTCacheVersion} mutableCopy];
    }
    if (!pending || [pending[@"failed"] boolValue]) return;
    NSString *scope = pending[@"scope"];
    NSMutableArray *errors = [NSMutableArray array];
    NSMutableArray *remaining = [NSMutableArray array];
    BOOL metadata = [scope isEqualToString:@"metadata"];
    BOOL playback = [scope isEqualToString:@"playback"] || [pending[@"playback"] boolValue];
    NSUInteger playbackRemoved = 0;
    NSUInteger removed = 0;
    NSArray *targets = nil;
    BOOL targetListKnown = NO;
    BOOL open = JPTResetFilesAreOpen(metadata, playback);
    if (metadata || playback) {
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
                NSString *resume = [[users stringByAppendingPathComponent:user] stringByAppendingPathComponent:@"context_player_state_restore"];
                if ((metadata && [fm fileExistsAtPath:path]) || (playback && [fm fileExistsAtPath:resume])) [found addObject:user];
            }
            targets = found;
        }
        if (metadata && !targets.count && !pending[@"remaining"]) {
            [errors addObject:@"no metadata database found; cache version unchanged"];
        }
        if (open) [errors addObject:@"selected cache already open; deletion skipped"];
        for (NSString *user in targets) {
            // The stored retry list contains directory names only, never arbitrary paths.
            if (![user isKindOfClass:[NSString class]] || !user.length || ![user isEqualToString:user.lastPathComponent]
                || [user isEqualToString:@"."] || [user isEqualToString:@".."]) {
                [errors addObject:@"invalid retry target"]; continue;
            }
            NSString *dir = [users stringByAppendingPathComponent:user];
            NSString *db = [dir stringByAppendingPathComponent:@"primary.ldb"];
            NSError *error = nil;
            BOOL safeParent = !open && JPTPlainDirectory(users) && JPTPlainDirectory(dir);
            NSString *resume = [dir stringByAppendingPathComponent:@"context_player_state_restore"];
            if (playback && [fm fileExistsAtPath:resume]) {
                struct stat info;
                BOOL safeResume = safeParent && lstat(resume.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode);
                if (safeResume && [fm removeItemAtPath:resume error:&error]) playbackRemoved++;
                else {
                    [remaining addObject:user];
                    [errors addObject:error ? [NSString stringWithFormat:@"playback deletion %@/%ld", error.domain, (long)error.code] : @"unsafe/open playback state; reset skipped"];
                    continue;
                }
            }
            if (!metadata || ![fm fileExistsAtPath:db]) continue;
            BOOL safe = safeParent && JPTPlainDirectory(db);
            if (safe && [fm removeItemAtPath:db error:&error]) removed++;
            else {
                [remaining addObject:user];
                [errors addObject:error ? [NSString stringWithFormat:@"deletion %@/%ld", error.domain, (long)error.code] : @"unsafe/open database; deletion skipped"];
            }
        }
    }
    if (![scope isEqualToString:@"playback"]) {
        [defaults removeObjectForKey:kJPTArtistNamesKey];
        [defaults removeObjectForKey:@"JPOriginalTitlesCreditsPreviousMetadataV1"];
    }
    BOOL ok = errors.count == 0;
    NSMutableDictionary *result = [@{@"scope": scope ?: @"plugin", @"date": [NSDate date].description,
        @"success": @(ok), @"removed": @(removed), @"databaseOpen": @(open), @"errors": errors} mutableCopy];
    result[@"usersPath"] = users ?: @"";
    result[@"targets"] = @(targets.count);
    result[@"playback"] = @(playback);
    result[@"playbackRemoved"] = @(playbackRemoved);
    result[@"usersExist"] = @([[NSFileManager defaultManager] fileExistsAtPath:users]);
    if (pending[@"migration"]) result[@"migration"] = pending[@"migration"];
    [defaults setObject:result forKey:kJPTLastResetKey];
    if (ok) {
        [defaults removeObjectForKey:kJPTPendingResetKey];
        if (pending[@"migration"] && migration) [defaults setObject:kJPTCacheVersion forKey:kJPTCacheVersionKey];
    } else {
        pending[@"failed"] = @YES;
        // Re-enumerate only when enumeration itself failed; otherwise retry failed targets alone.
        if (targetListKnown) pending[@"remaining"] = remaining;
        [defaults setObject:pending forKey:kJPTPendingResetKey];
    }
    [defaults synchronize];
    JPTLog(@"startup reset %@: removed %lu, playback removed %lu, open %d, errors %lu", scope, (unsigned long)removed, (unsigned long)playbackRemoved, open, (unsigned long)errors.count);
}

// Persist before quitting; retries retain only the targets that previously failed.
static BOOL JPTSavePendingReset(NSUserDefaults *defaults, NSString *scope, BOOL playback, BOOL retry) {
    id previous = [defaults objectForKey:kJPTPendingResetKey];
    NSMutableDictionary *pending = retry ? [[defaults dictionaryForKey:kJPTPendingResetKey] mutableCopy] : [NSMutableDictionary dictionary];
    if (!pending) return NO;
    pending[@"scope"] = scope;
    if (!retry) pending[@"playback"] = @(playback);
    [pending removeObjectForKey:@"failed"];
    [defaults setObject:pending forKey:kJPTPendingResetKey];
    if ([defaults synchronize]) return YES;
    if (previous) [defaults setObject:previous forKey:kJPTPendingResetKey];
    else [defaults removeObjectForKey:kJPTPendingResetKey];
    [defaults synchronize];
    return NO;
}

static BOOL JPTMetadataPromptRequired(NSUserDefaults *defaults) {
    return ![defaults boolForKey:kJPTMetadataPromptKey] && ![defaults objectForKey:kJPTPendingResetKey];
}

static BOOL JPTClaimMetadataPrompt(NSUserDefaults *defaults) {
    if (!JPTMetadataPromptRequired(defaults)) return NO;
    [defaults setBool:YES forKey:kJPTMetadataPromptKey];
    return [defaults synchronize];
}

static BOOL JPTMetadataPromptChoice(NSUserDefaults *defaults, BOOL confirm) {
    return !confirm || JPTSavePendingReset(defaults, @"metadata", NO, NO);
}

#ifndef JPT_MANAGEMENT_TEST
static BOOL gJPTMetadataPromptScheduled;
static BOOL gJPTMetadataPromptPresenting;

static UIViewController *JPTActivePresenter(void) {
    UIViewController *host = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow && !window.hidden) { host = window.rootViewController; break; }
        if (host) break;
    }
    while (host) {
        NSString *name = NSStringFromClass(host.class);
        if ([name containsString:@"Bluetooth"] && ([name containsString:@"Onboarding"]
            || [name containsString:@"Tutorial"] || [name containsString:@"Acquisition"])) return nil;
        if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) host = host.presentedViewController;
        else if ([host isKindOfClass:UINavigationController.class]) host = ((UINavigationController *)host).visibleViewController;
        else if ([host isKindOfClass:UITabBarController.class]) host = ((UITabBarController *)host).selectedViewController;
        else {
            UIViewController *visible = nil;
            for (UIViewController *child in host.childViewControllers.reverseObjectEnumerator) {
                if (child.isViewLoaded && child.view.window && !child.view.hidden && child.view.alpha > 0) {
                    CGRect rect = [child.view convertRect:child.view.bounds toView:nil], screen = child.view.window.bounds;
                    UIView *hit = [child.view.window hitTest:CGPointMake(screen.size.width / 2, screen.size.height / 2) withEvent:nil];
                    if (rect.size.width > 0 && rect.size.height > 0 && rect.origin.x < screen.size.width
                        && rect.origin.y < screen.size.height && rect.origin.x + rect.size.width > 0
                        && rect.origin.y + rect.size.height > 0 && [hit isDescendantOfView:child.view]) { visible = child; break; }
                }
            }
            if (!visible) break;
            host = visible;
        }
    }
    return host.isViewLoaded && host.view.window && host.view.bounds.size.width >= 300
        && host.view.bounds.size.height >= 300 && !host.isBeingDismissed && !host.isBeingPresented ? host : nil;
}

static void JPTScheduleMetadataPrompt(void) {
    if (gJPTMetadataPromptScheduled || gJPTMetadataPromptPresenting || !JPTMetadataPromptRequired(NSUserDefaults.standardUserDefaults)) return;
    gJPTMetadataPromptScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gJPTMetadataPromptScheduled = NO;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (!JPTMetadataPromptRequired(defaults) || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        UIViewController *host = JPTActivePresenter();
        if (!host || [host isKindOfClass:UIAlertController.class]) {
            JPTScheduleMetadataPrompt();
            return;
        }
        JPTLog(@"first-launch prompt presenter %@ bounds %@ window %@", NSStringFromClass(host.class),
               NSStringFromCGRect(host.view.bounds), NSStringFromCGRect(host.view.window.bounds));
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Refresh Spotify Metadata?"
            message:@"Clear cached Spotify metadata to improve original-name accuracy and collect previous names for Credits?\n\nSpotify will close. Reopen it to refresh metadata and resync the library online. Login, audio files and playback resume state are kept."
            preferredStyle:UIAlertControllerStyleAlert];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            JPTClaimMetadataPrompt(defaults);
            JPTMetadataPromptChoice(defaults, NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Confirm" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            JPTClaimMetadataPrompt(defaults);
            if (!JPTMetadataPromptChoice(defaults, YES)) {
                UIAlertController *error = [UIAlertController alertControllerWithTitle:@"Reset Not Saved"
                    message:@"Spotify will stay open. You can retry from Settings and privacy → Original Titles."
                    preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakAlert dismissViewControllerAnimated:YES completion:^{ [host presentViewController:error animated:YES completion:nil]; }];
                return;
            }
            JPTLog(@"first-launch metadata reset saved; quitting");
            dispatch_sync(JPTLogQueue(), ^{});
            exit(EXIT_SUCCESS);
        }]];
        gJPTMetadataPromptPresenting = YES;
        void (^verify)(void) = ^{
            gJPTMetadataPromptPresenting = NO;
            if (alert.presentingViewController && alert.isViewLoaded && alert.view.window) JPTClaimMetadataPrompt(defaults);
            else JPTScheduleMetadataPrompt();
        };
        [host presentViewController:alert animated:YES completion:verify];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (gJPTMetadataPromptPresenting) verify();
        });
    });
}

static void JPTInstallMetadataPrompt(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ JPTScheduleMetadataPrompt(); });
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ JPTScheduleMetadataPrompt(); });
}

@interface JPTManagementController : UITableViewController
@property (nonatomic) BOOL resetPlugin;
@property (nonatomic) BOOL resetMetadata;
@property (nonatomic) BOOL resetPlayback;
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
    self.navigationItem.rightBarButtonItem.enabled = self.resetPlugin || self.resetMetadata || self.resetPlayback || self.retryFailed;
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 4 : section == 1 ? 4 : 6; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @[@"Status", @"Diagnostics", @"Reset Options"][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"Logging is off by default. Logs may include track names and URIs. No authentication tokens or full responses are recorded. Two log files are retained, up to 1 MB each.";
    if (section == 2) return @"Select reset options, then tap Apply. Apply saves the request and closes the app immediately. Reopen Spotify to complete the reset. Metadata reset requires online resync and may discard unsynced offline changes. Playback resume reset deletes the saved queue and position without a backup. Select both metadata and playback resume resets to fix stale restored titles. Login, settings and audio files are kept; downloaded offline playback after reset is unverified.";
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
        if (index.row == 0) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · Spotify %@", kJPTBuild, kJPTBuildID, [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"];
        if (index.row == 1) cell.detailTextLabel.text = [NSString stringWithFormat:@"Core %@ · HttpClient %@", JPTDelegateHooked(@"SPTCoreURLSessionDataDelegate") ? @"installed" : @"unavailable", JPTDelegateHooked(@"Connectivity_HttpClientKit.HttpClientURLSession") ? @"installed" : @"unavailable"];
        if (index.row == 2) cell.detailTextLabel.text = [NSString stringWithFormat:@"Original tracks %lu · Artist names %lu", (unsigned long)JPTOriginalSnapshot().count, (unsigned long)JPTArtistNamesSnapshot().count];
        if (index.row == 3) cell.detailTextLabel.text = JPTResetSummary();
    } else if (index.section == 1) {
        cell.textLabel.text = @[@"Diagnostic Logging", @"Strict Mode", @"Export Diagnostics", @"Clear Logs"][index.row];
        if (index.row == 0) {
            cell.accessibilityIdentifier = @"jpt.logging";
            UISwitch *toggle = [UISwitch new]; toggle.on = atomic_load(&gJPTLogging); toggle.accessibilityIdentifier = @"jpt.logging";
            [toggle addTarget:self action:@selector(loggingChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
        } else if (index.row == 1) {
            cell.detailTextLabel.text = @"Fail the request when an original-name lookup fails instead of delivering names without enhancement. Pages may fail to load.";
            cell.accessibilityIdentifier = @"jpt.strict";
            UISwitch *toggle = [UISwitch new]; toggle.on = JPTStrictMode(); toggle.accessibilityIdentifier = @"jpt.strict";
            [toggle addTarget:self action:@selector(strictChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
        } else cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = @[@"Reset Plugin Name Cache", @"Reset Spotify Metadata and Library Index", @"Reset Playback Resume State", @"Retry Failed Reset", @"Pending Reset", @"Cancel Pending Reset"][index.row];
        if (index.row == 0) {
            cell.detailTextLabel.text = @"Clear original-track lookups and learned artist names.";
            [self checkbox:cell selected:self.resetPlugin identifier:@"jpt.reset.plugin"];
        } else if (index.row == 1) {
            cell.detailTextLabel.text = @"Also reset the plugin cache. Spotify must resync online.";
            [self checkbox:cell selected:self.resetMetadata identifier:@"jpt.reset.metadata"];
        } else if (index.row == 2) {
            cell.detailTextLabel.text = @"Delete the saved playback queue and position. No backup is created.";
            [self checkbox:cell selected:self.resetPlayback identifier:@"jpt.reset.playback"];
        } else if (index.row == 3) {
            if ([pending[@"failed"] boolValue]) {
                cell.detailTextLabel.text = JPTSelectionName(pending);
                [self checkbox:cell selected:self.retryFailed identifier:@"jpt.reset.retry"];
            } else { cell.detailTextLabel.text = @"No failed reset"; cell.textLabel.textColor = [UIColor secondaryLabelColor]; }
        } else if (index.row == 4) {
            cell.detailTextLabel.text = pending ? [NSString stringWithFormat:@"%@ · %@", JPTSelectionName(pending), [pending[@"failed"] boolValue] ? @"Failed" : @"On next launch"] : @"None";
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
- (void)strictChanged:(UISwitch *)toggle { JPTSetStrictMode([NSUserDefaults standardUserDefaults], toggle.on); }
- (void)apply {
    if (!self.resetPlugin && !self.resetMetadata && !self.resetPlayback && !self.retryFailed) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *scope = self.retryFailed ? [defaults dictionaryForKey:kJPTPendingResetKey][@"scope"] : self.resetMetadata ? @"metadata" : self.resetPlugin ? @"plugin" : @"playback";
    if (!JPTSavePendingReset(defaults, scope, self.resetPlayback, self.retryFailed)) {
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
    if (index.section == 1 && index.row == 2) [self exportFrom:[tableView cellForRowAtIndexPath:index]];
    if (index.section == 1 && index.row == 3) {
        dispatch_async(JPTLogQueue(), ^{
            [[NSFileManager defaultManager] removeItemAtPath:JPTLogPath() error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:[JPTLogPath() stringByAppendingString:@".1"] error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self message:@"Logs Cleared" body:@"The diagnostic logging setting is unchanged."]; });
        });
    }
    if (index.section != 2) return;
    if (index.row == 0) { self.retryFailed = NO; self.resetPlugin = !self.resetPlugin; if (!self.resetPlugin) self.resetMetadata = NO; }
    if (index.row == 1) { self.retryFailed = NO; self.resetMetadata = !self.resetMetadata; if (self.resetMetadata) self.resetPlugin = YES; }
    if (index.row == 2) { self.retryFailed = NO; self.resetPlayback = !self.resetPlayback; }
    if (index.row == 3 && [pending[@"failed"] boolValue]) { self.retryFailed = !self.retryFailed; self.resetPlugin = NO; self.resetMetadata = NO; self.resetPlayback = NO; }
    if (index.row == 5 && pending) { [defaults removeObjectForKey:kJPTPendingResetKey]; [defaults synchronize]; self.retryFailed = NO; JPTLog(@"pending reset cancelled"); }
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
        JPTLoadStrictMode([NSUserDefaults standardUserDefaults]);
        JPTProcessReset(JPTUsersPath(), [NSUserDefaults standardUserDefaults]);
        JPTInitializeNetwork(); JPTInstallManagementHook(); JPTInstallMetadataPrompt();
    }
}
#endif
