// Exercise the real logger and reset helpers against isolated temporary data.
#define JPT_MANAGEMENT_TEST 1
#import <Foundation/Foundation.h>
static NSString *const kJPTArtistNamesKey = @"JPOriginalTitlesArtistNames";
#include "../JPTManagement.m"

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
        JPTProcessReset(users, defaults);
        Check(!Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && !Exists([users stringByAppendingPathComponent:@"two-user/primary.ldb"])
              && Exists(storage) && [[defaults stringForKey:kJPTCacheVersionKey] isEqualToString:@"6"], @"migration resets only target databases and stays v6");
        CreateDatabase(users, @"one-user");
        JPTProcessReset(users, defaults);
        Check(Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"]), @"same version does not repeat migration");
        [defaults setObject:@{@"artist": @"name"} forKey:kJPTArtistNamesKey];
        [defaults setObject:@{@"scope": @"plugin"} forKey:kJPTPendingResetKey];
        JPTProcessReset(users, defaults);
        Check(![defaults objectForKey:kJPTArtistNamesKey] && Exists([users stringByAppendingPathComponent:@"one-user/primary.ldb"])
              && ![defaults objectForKey:kJPTPendingResetKey], @"plugin-only reset keeps Spotify database");
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
        [defaults removePersistentDomainForName:suite];
        [fm removeItemAtPath:root error:nil];
    }
    return 0;
}
