// Shared durable storage. Reads remain in memory; response delivery commits changed rows.
#ifndef JPT_STORAGE
#define JPT_STORAGE
#import <sqlite3.h>

static sqlite3 *gJPTStore;
static NSMutableDictionary *gArtistNames;
static NSMutableDictionary *gJPTDirtyArtists;
static NSString *gJPTStorageError;

static NSObject *JPTStorageLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *JPTStoragePath(void) {
#if defined(JPT_TEST) || defined(JPT_MANAGEMENT_TEST)
    NSString *path = NSProcessInfo.processInfo.environment[@"JPT_TEST_DATABASE_PATH"];
    if (path) return path;
    static NSString *temporary;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"jpt-store-%@/metadata.sqlite3", NSUUID.UUID.UUIDString]]; });
    return temporary;
#else
    return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"JPOriginalTitles/metadata.sqlite3"];
#endif
}

static BOOL JPTStorageExec(const char *sql) {
    int rc = sqlite3_exec(gJPTStore, sql, NULL, NULL, NULL);
    if (rc == SQLITE_OK) return YES;
    gJPTStorageError = [NSString stringWithFormat:@"SQLite error %d", rc];
    return NO;
}

static BOOL JPTStorageOpen(void) {
    if (gJPTStore) return YES;
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtPath:JPTStoragePath().stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:&error]) {
        gJPTStorageError = [NSString stringWithFormat:@"Storage directory error %ld", (long)error.code];
        return NO;
    }
    int rc = sqlite3_open_v2(JPTStoragePath().fileSystemRepresentation, &gJPTStore,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        gJPTStorageError = [NSString stringWithFormat:@"SQLite open error %d", rc];
        sqlite3_close(gJPTStore); gJPTStore = NULL; return NO;
    }
    sqlite3_busy_timeout(gJPTStore, 3000);
    if (!JPTStorageExec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;"
        "CREATE TABLE IF NOT EXISTS artist_names (uri TEXT PRIMARY KEY, name TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS previous_fields (uri TEXT NOT NULL, field TEXT NOT NULL,"
        "old_value TEXT NOT NULL, new_value TEXT NOT NULL, rank INTEGER NOT NULL, PRIMARY KEY(uri,field));")) {
        sqlite3_close(gJPTStore); gJPTStore = NULL; return NO;
    }
    gJPTStorageError = nil;
    return YES;
}

static NSString *JPTStorageString(sqlite3_stmt *stmt, int column) {
    const char *text = (const char *)sqlite3_column_text(stmt, column);
    return text ? [NSString stringWithUTF8String:text] : nil;
}

static NSMutableDictionary *JPTStorageLoad(BOOL previous) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (!JPTStorageOpen()) return result;
    sqlite3_stmt *stmt = NULL;
    const char *sql = previous ? "SELECT uri,field,old_value,new_value,rank FROM previous_fields"
                               : "SELECT uri,name FROM artist_names";
    int rc = sqlite3_prepare_v2(gJPTStore, sql, -1, &stmt, NULL);
    if (rc == SQLITE_OK) while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        NSString *uri = JPTStorageString(stmt, 0);
        if (!uri) continue;
        if (!previous) {
            NSString *name = JPTStorageString(stmt, 1);
            if ([uri hasPrefix:@"spotify:artist:"] && name.length) result[uri] = name;
        } else {
            NSString *field = JPTStorageString(stmt, 1), *old = JPTStorageString(stmt, 2), *now = JPTStorageString(stmt, 3);
            NSInteger rank = sqlite3_column_int(stmt, 4);
            if (![uri hasPrefix:@"spotify:track:"] || ![@[@"title", @"artists", @"album"] containsObject:field]
                || !old.length || !now.length || [old isEqual:now] || rank < 1 || rank > 3) continue;
            NSMutableDictionary *record = result[uri];
            if (!record) result[uri] = record = [@{@"fields": [NSMutableDictionary dictionary]} mutableCopy];
            record[@"fields"][field] = @{@"old": old, @"new": now, @"rank": @(rank)};
        }
    }
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        gJPTStorageError = [NSString stringWithFormat:@"SQLite read error %d", rc];
        [result removeAllObjects];
    }
    return result;
}

static NSMutableDictionary *JPTArtistNamesSnapshot(void) {
    @synchronized (JPTStorageLock()) {
        if (!gArtistNames) gArtistNames = JPTStorageLoad(NO);
        return [gArtistNames mutableCopy];
    }
}

static void JPTMergeArtistNames(NSDictionary *names) {
    @synchronized (JPTStorageLock()) {
        if (!gArtistNames) gArtistNames = JPTStorageLoad(NO);
        if (!gJPTDirtyArtists) gJPTDirtyArtists = [NSMutableDictionary dictionary];
        for (NSString *uri in names) {
            NSString *name = names[uri];
            if (![uri hasPrefix:@"spotify:artist:"] || ![name isKindOfClass:NSString.class] || !name.length) continue;
            if (![gArtistNames[uri] isEqual:name]) {
                gArtistNames[uri] = name;
                gJPTDirtyArtists[uri] = name;
            }
        }
    }
}

static BOOL JPTStorageRow(const char *sql, NSArray *values) {
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(gJPTStore, sql, -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        for (NSUInteger i = 0; i < values.count && rc == SQLITE_OK; i++) {
            id value = values[i];
            rc = [value isKindOfClass:NSNumber.class] ? sqlite3_bind_int64(stmt, (int)i + 1, [value longLongValue])
                : sqlite3_bind_text(stmt, (int)i + 1, [value UTF8String], -1, SQLITE_TRANSIENT);
        }
        if (rc == SQLITE_OK) rc = sqlite3_step(stmt);
    }
    sqlite3_finalize(stmt);
    if (rc == SQLITE_DONE) return YES;
    gJPTStorageError = [NSString stringWithFormat:@"SQLite write error %d", rc];
    return NO;
}

// Called under the shared lock; only changed fields enter this transaction.
static BOOL JPTStorageCommit(NSArray *previousChanges) {
    if (!gJPTDirtyArtists.count && !previousChanges.count) return YES;
    if (!JPTStorageOpen() || !JPTStorageExec("BEGIN IMMEDIATE")) return NO;
    BOOL ok = YES;
    for (NSString *uri in gJPTDirtyArtists) {
        if (!(ok = JPTStorageRow("INSERT OR REPLACE INTO artist_names(uri,name) VALUES(?,?)", @[uri, gJPTDirtyArtists[uri]]))) break;
    }
    if (ok) for (NSDictionary *change in previousChanges) {
        NSDictionary *pair = change[@"pair"];
        ok = pair ? JPTStorageRow("INSERT OR REPLACE INTO previous_fields(uri,field,old_value,new_value,rank) VALUES(?,?,?,?,?)",
            @[change[@"uri"], change[@"field"], pair[@"old"], pair[@"new"], pair[@"rank"]])
            : JPTStorageRow("DELETE FROM previous_fields WHERE uri=? AND field=?", @[change[@"uri"], change[@"field"]]);
        if (!ok) break;
    }
    if (ok) ok = JPTStorageExec("COMMIT");
    if (!ok) { sqlite3_exec(gJPTStore, "ROLLBACK", NULL, NULL, NULL); return NO; }
    [gJPTDirtyArtists removeAllObjects];
    gJPTStorageError = nil;
    return YES;
}

static BOOL JPTStorageClear(void) {
    @synchronized (JPTStorageLock()) {
        if (!JPTStorageOpen() || !JPTStorageExec("BEGIN IMMEDIATE")) return NO;
        if (!JPTStorageExec("DELETE FROM artist_names; DELETE FROM previous_fields; COMMIT;")) {
            sqlite3_exec(gJPTStore, "ROLLBACK", NULL, NULL, NULL); return NO;
        }
        [gArtistNames removeAllObjects]; [gJPTDirtyArtists removeAllObjects];
        return YES;
    }
}

static NSString *JPTStorageSummary(void) {
    @synchronized (JPTStorageLock()) {
        if (!JPTStorageOpen()) return gJPTStorageError ?: @"Database unavailable";
        sqlite3_stmt *stmt = NULL;
        sqlite3_int64 artists = 0, fields = 0, tracks = 0;
        int rc = sqlite3_prepare_v2(gJPTStore, "SELECT (SELECT count(*) FROM artist_names),count(*),count(DISTINCT uri) FROM previous_fields", -1, &stmt, NULL);
        if (rc == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
            artists = sqlite3_column_int64(stmt, 0); fields = sqlite3_column_int64(stmt, 1); tracks = sqlite3_column_int64(stmt, 2);
        }
        sqlite3_finalize(stmt);
        unsigned long long bytes = [[NSFileManager.defaultManager attributesOfItemAtPath:JPTStoragePath() error:nil][NSFileSize] unsignedLongLongValue];
        return [NSString stringWithFormat:@"SQLite · %lld artist names · %lld previous fields / %lld tracks · %@%@", artists, fields, tracks,
            [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile],
            gJPTStorageError ? [@" · " stringByAppendingString:gJPTStorageError] : @""];
    }
}
#endif
