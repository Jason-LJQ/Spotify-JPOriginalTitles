// Verify row-scoped durability and response-boundary atomicity with the production helpers.
#define JPT_TEST 1
#include "../JPOriginalTitles.m"
static void Check(BOOL ok, NSString *label) { if (!ok) { fprintf(stderr,"FAIL %s\n",label.UTF8String); exit(1); } printf("PASS %s\n",label.UTF8String); }
static NSDictionary *Carrier(NSString *uri, NSString *title) { return @{[@"178|" stringByAppendingString:uri]: @[@{@"title":title}]}; }
static NSInteger Count(NSString *sql) {
    sqlite3_stmt *stmt = NULL; sqlite3_prepare_v2(gJPTStore,sql.UTF8String,-1,&stmt,NULL);
    NSInteger n = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt,0) : -1; sqlite3_finalize(stmt); return n;
}
static int commits, begins;
static int Trace(unsigned kind, void *context, void *statement, void *unused) {
    const char *sql = sqlite3_sql(statement);
    if (sql && strcmp(sql,"COMMIT")==0) commits++;
    if (sql && strcmp(sql,"BEGIN IMMEDIATE")==0) begins++;
    return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc == 2) {
        setenv("JPT_TEST_DATABASE_PATH",argv[1],1);
        Check([JPTArtistNamesSnapshot()[@"spotify:artist:a"] isEqual:@"Artist"], @"fresh process loads committed artist");
        Check([JPTPreviousFields(@"spotify:track:t")[@"title"] isEqual:@"Raw"], @"fresh process loads committed previous field");
        return 0;
    }
    NSString *path = JPTStoragePath();
    Check(JPTStorageOpen(), @"database opens in plugin directory");
    Check(Count(@"SELECT count(*) FROM sqlite_master WHERE type='table'")==2, @"exactly two independent tables");
    Check(Count(@"PRAGMA synchronous")==2, @"FULL synchronous durability");
    Check(JPTStorageClear(), @"clear both tables in one transaction");
    sqlite3_trace_v2(gJPTStore, SQLITE_TRACE_STMT, Trace, NULL);
    JPTMergeArtistNames(@{@"spotify:artist:a":@"Artist"});
    Check([JPTArtistNamesSnapshot()[@"spotify:artist:a"] isEqual:@"Artist"], @"new artist immediately available in memory");
    Check(Count(@"SELECT count(*) FROM artist_names")==0 && commits==0, @"artist merge stages without writing whole dictionary");
    NSDictionary *before = Carrier(@"spotify:track:t",@"Raw"), *after = Carrier(@"spotify:track:t",@"New");
    Check(JPTPreviousCompare(before,after), @"delivery commits artist and previous field");
    Check(commits==1 && begins==1, @"one response uses exactly one transaction");
    Check(Count(@"SELECT count(*) FROM artist_names")==1 && Count(@"SELECT count(*) FROM previous_fields")==1, @"both changes durable before capture returns");
    int changes = sqlite3_total_changes(gJPTStore);
    JPTMergeArtistNames(JPTArtistNamesSnapshot()); JPTPreviousCompare(before,after);
    Check(commits==1 && sqlite3_total_changes(gJPTStore)==changes, @"unchanged response writes no rows or transaction");
    JPTPreviousCompare(Carrier(@"spotify:track:two",@"Other raw"), Carrier(@"spotify:track:two",@"Other new"));
    Check(sqlite3_total_changes(gJPTStore)==changes+1, @"new response writes only one changed field");
    changes = sqlite3_total_changes(gJPTStore);
    JPTPreviousCompare(Carrier(@"spotify:track:two",@"Official"), Carrier(@"spotify:track:two",@"Official"));
    Check(sqlite3_total_changes(gJPTStore)==changes+1 && Count(@"SELECT count(*) FROM previous_fields")==1, @"invalidated field deletes only its row");
    Check([JPTStorageSummary() containsString:@"1 artist names"] && [JPTStorageSummary() containsString:@"1 previous fields / 1 tracks"], @"management statistics read persisted row counts");
    sqlite3_exec(gJPTStore,"CREATE TRIGGER reject_previous BEFORE INSERT ON previous_fields BEGIN SELECT RAISE(ABORT,'fixture'); END",NULL,NULL,NULL);
    JPTMergeArtistNames(@{@"spotify:artist:b":@"Second"});
    Check(!JPTPreviousCompare(Carrier(@"spotify:track:failed",@"Raw"),Carrier(@"spotify:track:failed",@"New")), @"failed transaction rejects delivery");
    Check(Count(@"SELECT count(*) FROM artist_names")==1 && Count(@"SELECT count(*) FROM previous_fields")==1, @"previous write failure rolls back artist write too");
    Check(!JPTPreviousFields(@"spotify:track:failed").count, @"uncommitted previous field never published to memory");
    Check(gJPTDirtyArtists.count==1, @"failed artist row remains staged for next successful delivery");
    sqlite3_exec(gJPTStore,"DROP TRIGGER reject_previous",NULL,NULL,NULL);
    Check(JPTPreviousCompare(Carrier(@"spotify:track:failed",@"Raw"),Carrier(@"spotify:track:failed",@"New")), @"new successful response can commit after rollback");
    Check(Count(@"SELECT count(*) FROM artist_names")==2 && Count(@"SELECT count(*) FROM previous_fields")==2, @"retry commits both rows");
    sqlite3 *reader = NULL; sqlite3_open(path.fileSystemRepresentation,&reader);
    sqlite3_exec(reader,"BEGIN; SELECT * FROM artist_names",NULL,NULL,NULL);
    sqlite3_busy_timeout(gJPTStore,10);
    Check(!JPTPreviousCompare(Carrier(@"spotify:track:locked",@"Raw"),Carrier(@"spotify:track:locked",@"New")), @"busy COMMIT rolls back rather than claiming durability");
    Check(!JPTPreviousFields(@"spotify:track:locked").count, @"commit failure leaves previous memory unchanged");
    sqlite3_exec(reader,"ROLLBACK",NULL,NULL,NULL); sqlite3_close(reader); sqlite3_busy_timeout(gJPTStore,3000);
    Check(Count(@"SELECT count(*) FROM previous_fields WHERE uri='spotify:track:locked'")==0, @"failed commit leaves no durable row");
    NSTask *child = [NSTask new]; child.executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[0]]]; child.arguments = @[path];
    [child launchAndReturnError:nil]; [child waitUntilExit]; Check(child.terminationStatus==0, @"new process observes transaction after parent delivery boundary");
    JPTStorageClear(); gJPTPreviousMetadataRecords=nil;
    dispatch_apply(64,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i) {
        NSString *uri=[NSString stringWithFormat:@"spotify:track:%zu",i];
        JPTPreviousCompare(Carrier(uri,@"Raw"),Carrier(uri,@"New"));
    });
    Check(Count(@"SELECT count(*) FROM previous_fields")==64 && JPTPreviousRecordCount()==64, @"parallel responses preserve all independent rows");
    gJPTPreviousMetadataRecords=nil; Check(JPTPreviousRecordCount()==64, @"parallel data survives memory reload");
    Check(JPTStorageClear(), @"explicit reset succeeds"); gJPTPreviousMetadataRecords=nil;
    Check(!JPTPreviousRecordCount() && !JPTArtistNamesSnapshot().count, @"reset clears both persistent and reloaded memory stores");
    sqlite3_stmt *integrity = NULL; sqlite3_prepare_v2(gJPTStore,"PRAGMA integrity_check",-1,&integrity,NULL);
    Check(sqlite3_step(integrity)==SQLITE_ROW && [JPTStorageString(integrity,0) isEqual:@"ok"], @"database integrity after rollback and concurrent writes");
    sqlite3_finalize(integrity);
    sqlite3_close(gJPTStore); gJPTStore=NULL;
    [NSFileManager.defaultManager removeItemAtPath:path.stringByDeletingLastPathComponent error:nil];
} return 0; }
