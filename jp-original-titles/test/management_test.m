// Exercise production maintenance against isolated storage and Spotify cache fixtures.
#define JPT_MANAGEMENT_TEST 1
#import <Foundation/Foundation.h>
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
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
    printf("PASS: %s\n",message.UTF8String);
}
static BOOL Exists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
static void CreateDatabase(NSString *users) {
    NSString *path = [users stringByAppendingPathComponent:@"user/primary.ldb"];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    [@"fixture" writeToFile:[path stringByAppendingPathComponent:@"LOCK"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void Seed(void) {
    JPTMergeArtistNames(@{@"spotify:artist:a": @"Artist"});
    JPTStorageCommit(@[@{@"uri": @"spotify:track:t", @"field": @"title", @"pair": @{@"old": @"Old", @"new": @"New", @"rank": @3}}]);
}
int main(void) { @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *users = [root stringByAppendingPathComponent:@"PersistentCache/Users"];
    NSString *db = [users stringByAppendingPathComponent:@"user/primary.ldb"];
    NSString *resume = [users stringByAppendingPathComponent:@"user/context_player_state_restore"];
    NSString *suite = [@"jpt.management." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    setenv("JPT_TEST_DATABASE_PATH", [[root stringByAppendingPathComponent:@"JPOriginalTitles/metadata.sqlite3"] UTF8String], 1);
    JPTLoadStrictMode(defaults); Check(!JPTStrictMode(), @"strict defaults off");
    JPTSetStrictMode(defaults, YES); Check(JPTStrictMode(), @"strict updates immediately");
    atomic_store(&gJPTStrict, false); JPTLoadStrictMode(defaults); Check(JPTStrictMode(), @"strict persists");
    JPTSetStrictMode(defaults, NO); Check(!JPTStrictMode(), @"strict turns off");
    Check(JPTMetadataPromptRequired(defaults), @"fresh version offers reset");
    [defaults setBool:YES forKey:kJPTMetadataPromptKey]; Check(JPTMetadataPromptRequired(defaults), @"legacy boolean does not suppress new version prompt");
    [defaults setObject:@"v7" forKey:kJPTMetadataPromptKey]; Check(JPTMetadataPromptRequired(defaults), @"older plugin version prompts again");
    Check(JPTMetadataPromptRequired(defaults), @"no choice leaves prompt available after interruption");
    Check(JPTMetadataPromptChoice(defaults, NO), @"cancel saves choice");
    Check(![defaults objectForKey:kJPTResetRequestKey], @"cancel schedules no reset");
    NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Check(!JPTMetadataPromptRequired(reopened), @"cancel persists after relaunch");
    [defaults setObject:@"v7" forKey:kJPTMetadataPromptKey];
    Check(JPTMetadataPromptChoice(defaults, YES), @"confirm saves request and choice");
    NSDictionary *request = [defaults dictionaryForKey:kJPTResetRequestKey];
    Check([request[@"metadata"] boolValue] && [request[@"plugin"] boolValue] && [request[@"playback"] boolValue], @"prompt selects all three caches including playback state");
    Check(!JPTMetadataPromptRequired(reopened), @"same version confirm does not repeat");
    [defaults removeObjectForKey:kJPTResetRequestKey];
    JPTUnsavedDefaults *unsaved = [JPTUnsavedDefaults new];
    Check(!JPTMetadataPromptChoice((id)unsaved, YES) && ![unsaved objectForKey:kJPTResetRequestKey], @"failed confirm leaves no latent reset");
    NSDictionary *prior = @{@"plugin": @YES}; [unsaved setObject:prior forKey:kJPTResetRequestKey];
    Check(!JPTSaveResetRequest((id)unsaved, NO, YES, NO) && [[unsaved objectForKey:kJPTResetRequestKey] isEqual:prior], @"failed save restores previous selection");
    Check(!JPTSaveResetRequest(defaults, NO, NO, NO), @"empty selection cannot quit");
    Seed(); CreateDatabase(users);
    [@"queue" writeToFile:resume atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [defaults setObject:@{@"legacy":@"ignored"} forKey:@"JPOriginalTitlesArtistNames"];
    [defaults setObject:@{@"legacy":@"ignored"} forKey:@"JPOriginalTitlesCreditsPreviousMetadataV1"];
    [defaults setObject:@{@"scope":@"metadata",@"failed":@YES} forKey:@"JPOriginalTitlesPendingReset"];
    JPTProcessReset(users, defaults);
    Check(Exists(db) && Exists(resume), @"legacy reset not replayed and upgrade does not erase Spotify data");
    Check(![defaults objectForKey:@"JPOriginalTitlesArtistNames"] && ![defaults objectForKey:@"JPOriginalTitlesCreditsPreviousMetadataV1"], @"legacy dictionaries discarded without migration");
    Check(![defaults objectForKey:@"JPOriginalTitlesPendingReset"], @"obsolete pending state removed");
    Check(JPTStorageLoad(NO).count == 1 && JPTStorageLoad(YES).count == 1, @"launch preserves existing SQLite data");
    JPTSaveResetRequest(defaults, NO, YES, NO); JPTProcessReset(users, defaults);
    Check(!Exists(db) && Exists(resume), @"Spotify-only reset clears metadata and keeps playback");
    Check(JPTStorageLoad(NO).count == 1 && JPTStorageLoad(YES).count == 1, @"Spotify-only reset preserves both plugin tables");
    Check(![defaults objectForKey:kJPTResetRequestKey], @"startup consumes request once");
    Check(!JPTMetadataPromptRequired(defaults), @"metadata reset retains version prompt choice");
    CreateDatabase(users); JPTSaveResetRequest(defaults, YES, NO, NO); JPTProcessReset(users, defaults);
    Check(Exists(db) && Exists(resume), @"plugin-only reset preserves Spotify data");
    Check(!JPTStorageLoad(NO).count && !JPTStorageLoad(YES).count, @"plugin reset clears both tables");
    Check(!JPTArtistNamesSnapshot().count, @"plugin reset clears artist memory");
    Check(!JPTMetadataPromptRequired(defaults), @"plugin reset retains version prompt choice");
    Seed(); JPTSaveResetRequest(defaults, NO, NO, YES); JPTProcessReset(users, defaults);
    Check(Exists(db) && !Exists(resume), @"playback-only reset preserves metadata");
    Check(JPTStorageLoad(NO).count == 1 && JPTStorageLoad(YES).count == 1, @"playback reset preserves plugin tables");
    [@"queue" writeToFile:resume atomically:YES encoding:NSUTF8StringEncoding error:nil];
    JPTSaveResetRequest(defaults, YES, YES, YES); JPTProcessReset(users, defaults);
    Check(!Exists(db) && !Exists(resume) && !JPTStorageLoad(NO).count && !JPTStorageLoad(YES).count, @"all selected resets clear exactly selected data");
    Check([[defaults dictionaryForKey:kJPTLastResetKey][@"date"] isKindOfClass:NSDate.class], @"reset stores absolute NSDate");
    NSTimeZone *originalZone = NSTimeZone.defaultTimeZone;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:0];
    [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"America/New_York"]];
    NSString *ny = JPTLocalResetDate(date);
    [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"Asia/Tokyo"]];
    Check(![ny isEqual:JPTLocalResetDate(date)], @"reset display follows current local timezone");
    Check(![JPTLocalResetDate(@"2026-10-16 23:00:00 +0000") isEqual:@"Unknown time"], @"old reset timestamps are formatted locally");
    [NSTimeZone setDefaultTimeZone:originalZone];
    CreateDatabase(users);
    int fd = open([[db stringByAppendingPathComponent:@"LOCK"] fileSystemRepresentation], O_RDONLY);
    JPTSaveResetRequest(defaults, NO, YES, NO); JPTProcessReset(users, defaults);
    Check(Exists(db) && ![[defaults dictionaryForKey:kJPTLastResetKey][@"success"] boolValue], @"open Spotify database is preserved and failure recorded");
    close(fd); JPTProcessReset(users, defaults);
    Check(Exists(db) && ![defaults objectForKey:kJPTResetRequestKey], @"failed request never automatically retries");
    JPTSaveResetRequest(defaults, NO, YES, NO); JPTProcessReset(users, defaults);
    Check(!Exists(db), @"new explicit selection clears closed cache");
    NSString *outside = [root stringByAppendingPathComponent:@"outside"];
    [NSFileManager.defaultManager createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:db withDestinationPath:outside error:nil];
    JPTSaveResetRequest(defaults, NO, YES, NO); JPTProcessReset(users, defaults);
    Check(Exists(outside) && Exists(db) && ![[defaults dictionaryForKey:kJPTLastResetKey][@"success"] boolValue], @"symlink metadata is preserved");
    [NSFileManager.defaultManager removeItemAtPath:db error:nil]; CreateDatabase(users);
    [NSFileManager.defaultManager createSymbolicLinkAtPath:resume withDestinationPath:outside error:nil];
    JPTSaveResetRequest(defaults, NO, YES, YES); JPTProcessReset(users, defaults);
    Check(Exists(resume) && Exists(db), @"unsafe playback link prevents partial deletion for that user");
    NSString *bad = [root stringByAppendingPathComponent:@"bad"];
    [@"file" writeToFile:bad atomically:YES encoding:NSUTF8StringEncoding error:nil];
    JPTSaveResetRequest(defaults, NO, YES, NO); JPTProcessReset(bad, defaults);
    Check(![[defaults dictionaryForKey:kJPTLastResetKey][@"success"] boolValue], @"enumeration failure is recorded");
    setenv("JPT_TEST_LOG_PATH", [[root stringByAppendingPathComponent:@"JPOriginalTitles.log"] UTF8String], 1);
    NSString *log = JPTLogPath(); [@"old\n" writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    JPTLog(@"disabled"); dispatch_sync(JPTLogQueue(), ^{});
    Check([[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil] isEqual:@"old\n"], @"disabled logging leaves files alone");
    atomic_store(&gJPTLogging, true); JPTLog(@"enabled"); dispatch_sync(JPTLogQueue(), ^{});
    Check([[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil] containsString:@"enabled"], @"enabled logging appends");
    NSString *line = [@"x" stringByPaddingToLength:1900 withString:@"x" startingAtIndex:0];
    for (int i=0;i<1200;i++) JPTLog(@"%@",line); dispatch_sync(JPTLogQueue(), ^{});
    Check([[NSFileManager.defaultManager attributesOfItemAtPath:log error:nil][NSFileSize] unsignedIntegerValue] <= kJPTLogLimit && [[NSFileManager.defaultManager attributesOfItemAtPath:[log stringByAppendingString:@".1"] error:nil][NSFileSize] unsignedIntegerValue] <= kJPTLogLimit, @"both logs stay bounded");
    [defaults removePersistentDomainForName:suite];
    sqlite3_close(gJPTStore); gJPTStore = NULL;
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
} return 0; }
