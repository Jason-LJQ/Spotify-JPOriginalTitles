// Exercise the real logger and reset helpers against isolated temporary data.
#define JPT_MANAGEMENT_TEST 1
#import <Foundation/Foundation.h>
static NSString *const kJPTArtistNamesKey = @"JPOriginalTitlesArtistNames";
#include "../JPTManagement.m"

@interface JPTUnsavedDefaults : NSObject
@property (nonatomic, strong) NSMutableDictionary *values;
@end
@implementation JPTUnsavedDefaults
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary dictionary]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (BOOL)synchronize { return NO; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
    printf("PASS: %s\n", message.UTF8String);
}

static void CreateDatabase(NSString *users, NSString *name) {
    NSString *db = [[users stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"primary.ldb"];
    [[NSFileManager defaultManager] createDirectoryAtPath:db withIntermediateDirectories:YES attributes:nil error:nil];
    [@"fixture" writeToFile:[db stringByAppendingPathComponent:@"LOCK"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL Exists(NSString *path) { return [[NSFileManager defaultManager] fileExistsAtPath:path]; }

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"jpt-management-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *users = [root stringByAppendingPathComponent:@"PersistentCache/Users"];
        NSString *suite = [@"jpt.management.test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        JPTLoadStrictMode(defaults);
        Check(!JPTStrictMode(), @"strict mode defaults off");
        JPTSetStrictMode(defaults, YES);
        Check(JPTStrictMode() && [defaults boolForKey:kJPTStrictKey], @"strict mode changes immediately and is persisted");
        atomic_store(&gJPTStrict, false); JPTLoadStrictMode(defaults);
        Check(JPTStrictMode() && [JPTStrictSummary() isEqualToString:@"Strict mode: on"], @"diagnostic export summary includes persisted strict mode");
        JPTSetStrictMode(defaults, NO);
        Check(!JPTStrictMode() && [JPTStrictSummary() isEqualToString:@"Strict mode: off"], @"strict mode turns off immediately");
        Check(JPTMetadataPromptRequired(defaults), @"fresh installation offers metadata refresh");
        Check(JPTClaimMetadataPrompt(defaults) && !JPTMetadataPromptRequired(defaults), @"recorded first prompt prevents duplicate presentation");
        Check(JPTMetadataPromptChoice(defaults, NO) && ![defaults objectForKey:kJPTPendingResetKey], @"cancel does not schedule or clear metadata");
        NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Check(!JPTMetadataPromptRequired(reopened) && !JPTClaimMetadataPrompt(reopened), @"cancelled prompt stays hidden after relaunch");
        [defaults removeObjectForKey:kJPTMetadataPromptKey];
        [defaults setObject:@{@"scope": @"playback"} forKey:kJPTPendingResetKey];
        Check(!JPTMetadataPromptRequired(defaults) && !JPTClaimMetadataPrompt(defaults), @"pending maintenance is not overwritten by first prompt");
        [defaults removeObjectForKey:kJPTPendingResetKey];
        Check(JPTClaimMetadataPrompt(defaults) && JPTMetadataPromptChoice(defaults, YES), @"confirm persists the metadata reset request");
        NSDictionary *firstReset = [defaults dictionaryForKey:kJPTPendingResetKey];
        Check([firstReset[@"scope"] isEqual:@"metadata"] && ![firstReset[@"playback"] boolValue], @"first prompt never selects playback reset");
        Check(!JPTMetadataPromptRequired(reopened), @"confirmed prompt also stays hidden after relaunch");
        [defaults removeObjectForKey:kJPTPendingResetKey];
        JPTUnsavedDefaults *unsaved = [JPTUnsavedDefaults new];
        Check(!JPTMetadataPromptChoice((NSUserDefaults *)unsaved, YES) && ![unsaved objectForKey:kJPTPendingResetKey], @"failed confirmation leaves no reset that could persist later");
        NSDictionary *savedPending = @{@"scope": @"plugin", @"failed": @YES};
        [unsaved setObject:savedPending forKey:kJPTPendingResetKey];
        Check(!JPTSavePendingReset((NSUserDefaults *)unsaved, @"metadata", NO, NO)
              && [[unsaved objectForKey:kJPTPendingResetKey] isEqual:savedPending], @"failed save restores the previous pending reset");
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("JPT_TEST_LOG_PATH", [[root stringByAppendingPathComponent:@"JPOriginalTitles.log"] UTF8String], 1);
        NSString *log = JPTLogPath();
        [@"old log\n" writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
        JPTLog(@"disabled");
        dispatch_sync(JPTLogQueue(), ^{});
        Check([[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"old log\n"], @"disabled logging preserves existing logs");
        atomic_store(&gJPTLogging, YES);
        JPTLog(@"enabled");
        dispatch_sync(JPTLogQueue(), ^{});
        Check([[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil] containsString:@"enabled"], @"enabled logging appends");
        NSString *longLine = [@"x" stringByPaddingToLength:1900 withString:@"x" startingAtIndex:0];
        for (int i = 0; i < 1200; i++) JPTLog(@"%@", longLine);
        dispatch_sync(JPTLogQueue(), ^{});
        Check([[fm attributesOfItemAtPath:log error:nil][NSFileSize] unsignedIntegerValue] <= kJPTLogLimit
              && [[fm attributesOfItemAtPath:[log stringByAppendingString:@".1"] error:nil][NSFileSize] unsignedIntegerValue] <= kJPTLogLimit,
              @"rotation bounds both logs to 1 MB");
        NSString *legacy = [@"legacy\n" stringByPaddingToLength:2 * kJPTLogLimit withString:@"legacy\n" startingAtIndex:0];
        [legacy writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
        JPTLog(@"legacy rotation");
        dispatch_sync(JPTLogQueue(), ^{});
        Check([[fm attributesOfItemAtPath:[log stringByAppendingString:@".1"] error:nil][NSFileSize] unsignedIntegerValue] <= kJPTLogLimit,
              @"oversized legacy logs are bounded when logging resumes");
        atomic_store(&gJPTLogging, NO);
        CreateDatabase(users, @"one-user"); CreateDatabase(users, @"two-user");
        NSString *storage = [root stringByAppendingPathComponent:@"PersistentCache/Storage"];
        [fm createDirectoryAtPath:storage withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *resume = [users stringByAppendingPathComponent:@"one-user/context_player_state_restore"];
        NSData *resumeData = [@"saved playback state" dataUsingEncoding:NSUTF8StringEncoding];
        [resumeData writeToFile:resume atomically:YES];
        JPTProcessReset(users, defaults);
        Check(Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && Exists([users stringByAppendingPathComponent:@"two-user/primary.ldb"])
              && Exists(storage) && [[defaults stringForKey:kJPTCacheVersionKey] isEqualToString:kJPTCacheVersion], @"automatic migration preserves Spotify databases and records the plugin revision");
        Check(Exists(resume), @"plugin migration leaves playback resume state untouched");
        [defaults setObject:@{@"scope": @"metadata", @"migration": @"6.1.3", @"failed": @YES} forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check(Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && [[[defaults dictionaryForKey:kJPTLastResetKey] objectForKey:@"scope"] isEqualToString:@"plugin"],
              @"legacy automatic metadata reset becomes a plugin-only migration");
        CreateDatabase(users, @"one-user");
        JPTProcessReset(users, defaults);
        Check(Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"]), @"same version does not repeat migration");
        [defaults setObject:@{@"artist": @"name"} forKey:kJPTArtistNamesKey];
        [defaults setObject:@{@"track": @"previous"} forKey:@"JPOriginalTitlesCreditsPreviousMetadataV1"];
        [defaults setObject:@{@"scope": @"plugin"} forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check(![defaults objectForKey:kJPTArtistNamesKey] && Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && ![defaults objectForKey:kJPTPendingResetKey], @"plugin-only reset keeps Spotify database");
        Check(![defaults objectForKey:@"JPOriginalTitlesCreditsPreviousMetadataV1"], @"plugin reset clears previous metadata records");
        Check(!JPTMetadataPromptRequired(defaults), @"plugin cache reset does not show the first prompt again");
        int fd = open([[users stringByAppendingPathComponent:@"one-user/primary.ldb/LOCK"] fileSystemRepresentation], O_RDONLY);
        [defaults setObject:@{@"scope": @"metadata"} forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check([[defaults dictionaryForKey:kJPTPendingResetKey][@"failed"] boolValue]
              && Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"]), @"open database is preserved and reset reports failure");
        close(fd);
        JPTProcessReset(users, defaults);
        Check(Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"]), @"failed reset waits for explicit retry");
        NSMutableDictionary *retry = [[defaults dictionaryForKey:kJPTPendingResetKey] mutableCopy];
        [retry removeObjectForKey:@"failed"]; [defaults setObject:retry forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check(!Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"]), @"explicit retry clears the closed database");
        CreateDatabase(users, @"one-user");
        NSString *outside = [root stringByAppendingPathComponent:@"outside"];
        [fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createSymbolicLinkAtPath:[users stringByAppendingPathComponent:@"two-user/primary.ldb"] withDestinationPath:outside error:nil];
        [defaults setObject:@{@"scope": @"metadata"} forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check(Exists(outside) && !Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && [[defaults dictionaryForKey:kJPTPendingResetKey][@"remaining"] isEqual:@[@"two-user"]], @"partial failure preserves symlinks and records only failed targets");
        CreateDatabase(users, @"one-user");
        [fm removeItemAtPath:[users stringByAppendingPathComponent:@"two-user/primary.ldb"] error:nil];
        CreateDatabase(users, @"two-user");
        retry = [[defaults dictionaryForKey:kJPTPendingResetKey] mutableCopy];
        [retry removeObjectForKey:@"failed"]; [defaults setObject:retry forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check(Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && !Exists([users stringByAppendingPathComponent:@"two-user/primary.ldb"]), @"partial retry does not wipe a successfully rebuilt database");
        NSString *bad = [root stringByAppendingPathComponent:@"not-a-directory"];
        [@"fixture" writeToFile:bad atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [defaults setObject:@{@"scope": @"metadata"} forKey:kJPTPendingResetKey];
        JPTProcessReset(bad, defaults);
        Check([[defaults dictionaryForKey:kJPTPendingResetKey][@"failed"] boolValue]
              && ![defaults dictionaryForKey:kJPTPendingResetKey][@"remaining"], @"enumeration failure is not success and retry will re-enumerate");
        [defaults removeObjectForKey:kJPTPendingResetKey];
        [defaults setObject:@"6" forKey:kJPTCacheVersionKey];
        CreateDatabase(users, @"one-user");
        JPTProcessReset(users, defaults);
        Check(Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && [[defaults stringForKey:kJPTCacheVersionKey] isEqualToString:kJPTCacheVersion], @"v6 migration preserves Spotify metadata while updating plugin state");
        Check(JPTSavePendingReset(defaults, @"metadata", NO, NO)
              && [[defaults dictionaryForKey:kJPTPendingResetKey][@"scope"] isEqualToString:@"metadata"], @"Apply persists selected reset before exit");
        [defaults setObject:@{@"scope": @"metadata", @"failed": @YES, @"remaining": @[@"one-user"]} forKey:kJPTPendingResetKey];
        Check(JPTSavePendingReset(defaults, @"metadata", NO, YES)
              && ![defaults dictionaryForKey:kJPTPendingResetKey][@"failed"]
              && [[defaults dictionaryForKey:kJPTPendingResetKey][@"remaining"] isEqual:@[@"one-user"]], @"Apply retry retains only failed targets");
        [defaults removeObjectForKey:kJPTPendingResetKey];
        Check(!JPTSavePendingReset(defaults, @"metadata", NO, YES), @"Apply retry without saved request does not quit");
        [defaults removeObjectForKey:kJPTPendingResetKey];
        [defaults removeObjectForKey:kJPTLastResetKey];
        [defaults setObject:@"6" forKey:kJPTCacheVersionKey];
        JPTProcessReset([root stringByAppendingPathComponent:@"missing-users"], defaults);
        Check(![defaults dictionaryForKey:kJPTPendingResetKey]
              && [[defaults stringForKey:kJPTCacheVersionKey] isEqualToString:kJPTCacheVersion], @"plugin migration succeeds without a Spotify metadata directory");
        [defaults removeObjectForKey:kJPTPendingResetKey];
        [defaults setObject:kJPTCacheVersion forKey:kJPTCacheVersionKey];
        CreateDatabase(users, @"one-user");
        [fm removeItemAtPath:resume error:nil];
        [fm createSymbolicLinkAtPath:resume withDestinationPath:outside error:nil];
        [defaults setObject:@{@"scope": @"metadata", @"playback": @YES} forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check([[defaults dictionaryForKey:kJPTPendingResetKey][@"failed"] boolValue]
              && Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"]) && Exists(outside),
              @"unsafe playback-state link is preserved and prevents database deletion");
        [fm removeItemAtPath:resume error:nil];
        [resumeData writeToFile:resume atomically:YES];
        [defaults setObject:@{@"artist": @"name"} forKey:kJPTArtistNamesKey];
        Check(JPTSavePendingReset(defaults, @"playback", YES, NO), @"playback-only Apply persists the third option");
        JPTProcessReset(users, defaults);
        Check(!Exists(resume) && Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && [defaults objectForKey:kJPTArtistNamesKey], @"playback-only reset preserves metadata and plugin caches");
        Check([[defaults dictionaryForKey:kJPTLastResetKey][@"playbackRemoved"] unsignedIntegerValue] == 1
              && ![defaults dictionaryForKey:kJPTLastResetKey][@"resumeBackups"], @"playback reset deletes directly without creating backup records");
        [resumeData writeToFile:resume atomically:YES];
        JPTSavePendingReset(defaults, @"metadata", NO, NO);
        JPTProcessReset(users, defaults);
        Check(Exists(resume), @"explicit metadata-only reset does not select playback implicitly");
        CreateDatabase(users, @"one-user");
        JPTSavePendingReset(defaults, @"metadata", YES, NO);
        JPTProcessReset(users, defaults);
        Check(!Exists(resume) && !Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"]),
              @"combined metadata and playback reset clears both selected caches");
        NSArray *files = [fm contentsOfDirectoryAtPath:[users stringByAppendingPathComponent:@"one-user"] error:nil];
        Check(!files.count, @"selected playback deletion leaves no backup file");
        [defaults setObject:@{@"scope": @"metadata", @"playback": @YES, @"failed": @YES, @"remaining": @[@"one-user"]} forKey:kJPTPendingResetKey];
        JPTSavePendingReset(defaults, @"metadata", NO, YES);
        Check([[defaults dictionaryForKey:kJPTPendingResetKey][@"playback"] boolValue], @"retry retains the failed playback selection");
        [defaults removePersistentDomainForName:suite];
        [fm removeItemAtPath:root error:nil];
    }
    return 0;
}
