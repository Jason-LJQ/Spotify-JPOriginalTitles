#define JPT_TEST 1
#include "../JPOriginalTitles.m"

static NSUInteger checks;
static void Check(BOOL condition, NSString *label) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL %s\n", label.UTF8String); exit(1); }
}
static void Reset(void) {
    @synchronized (JPTPreviousLock()) {
        gJPTPreviousMetadataRecords = [NSMutableDictionary dictionary];
        JPTStorageClear();
    }
}
static NSData *Value(NSString *title, NSString *album, NSArray *artists, BOOL identity) {
    NSMutableData *v = [NSMutableData data];
    if (title) JPTWriteString(v, 2, title);
    if (album) {
        NSMutableData *p = [NSMutableData data];
        JPTWriteString(p, identity ? 1 : 2, album);
        JPTWriteData(v, identity ? 4 : 3, p);
    }
    for (id artist in artists) {
        NSMutableData *a = [NSMutableData data];
        if ([artist isKindOfClass:NSString.class]) JPTWriteString(a, identity ? 1 : 2, artist);
        JPTWriteData(v, identity ? 5 : 4, a);
    }
    return v;
}
static NSData *Response(NSString *uri, NSData *value, uint64_t kind) {
    NSMutableData *header = [NSMutableData data]; JPTWriteVarint(header, 8); JPTWriteVarint(header, 200);
    NSMutableData *any = [NSMutableData data]; JPTWriteData(any, 2, value);
    NSMutableData *entry = [NSMutableData data]; JPTWriteData(entry, 1, header); JPTWriteString(entry, 2, uri); JPTWriteData(entry, 3, any);
    NSMutableData *array = [NSMutableData data]; JPTWriteVarint(array, 16); JPTWriteVarint(array, kind); JPTWriteData(array, 3, entry);
    NSMutableData *body = [NSMutableData data]; JPTWriteData(body, 2, array); return body;
}
static NSData *Join(NSData *a, NSData *b) { NSMutableData *out = [a mutableCopy]; [out appendData:b]; return out; }
static NSData *Search(NSString *uri, NSString *title, NSString *album, NSArray *artists) {
    NSMutableData *entity = [NSMutableData data]; JPTWriteString(entity, 1, uri);
    if (title) JPTWriteString(entity, 2, title);
    NSMutableData *track = [NSMutableData data];
    if (album) { NSMutableData *a = [NSMutableData data]; JPTWriteString(a, 1, @"spotify:album:test"); JPTWriteString(a, 2, album); JPTWriteData(track, 3, a); }
    for (NSString *name in artists) { NSMutableData *a = [NSMutableData data]; JPTWriteString(a, 1, @"spotify:artist:test"); JPTWriteString(a, 2, name); JPTWriteData(track, 4, a); }
    JPTWriteData(entity, 5, track); NSMutableData *out = [NSMutableData data]; JPTWriteData(out, 1, entity); return out;
}
int main(void) {
    @autoreleasepool {
        NSString *uri = @"spotify:track:one", *two = @"spotify:track:two";
        NSArray *fields = @[@"title", @"album", @"artists"];
        for (NSNumber *kind in @[@178, @10]) {
            BOOL identity = kind.intValue == 178;
            for (NSString *field in fields) {
                Reset();
                NSData *before = Response(uri, Value(@"Old title", @"Old album", @[@"Old artist", @"Second"], identity), kind.unsignedLongLongValue);
                NSData *after = Response(uri, Value([field isEqual:@"title"] ? @"New title" : @"Old title", [field isEqual:@"album"] ? @"New album" : @"Old album", [field isEqual:@"artists"] ? @[@"New artist", @"Second"] : @[@"Old artist", @"Second"], identity), kind.unsignedLongLongValue);
                JPTCapturePreviousResponse(before, after);
                NSDictionary *got = JPTPreviousFields(uri);
                Check(got.count == 1 && got[field] != nil, [NSString stringWithFormat:@"only changed %@ kind%@", field, kind]);
                Check(!JPTPreviousFields(two).count, @"URI isolation");
                if ([field isEqual:@"artists"]) Check([got[field] isEqual:@"Old artist, Second"], @"artist order");
            }
        }
        Reset();
        NSData *same = Response(uri, Value(@"Same", @"Album", @[@"Artist"], YES), 178);
        JPTCapturePreviousResponse(same, same);
        Check(!JPTPreviousFields(uri).count, @"unchanged");
        NSData *empty = Response(uri, Value(@"", nil, @[[NSNull null]], YES), 178);
        NSData *filled = Response(uri, Value(@"New", @"Album", @[@"Artist"], YES), 178);
        JPTCapturePreviousResponse(empty, filled);
        Check(!JPTPreviousFields(uri).count, @"empty and missing original fields");
        JPTCapturePreviousResponse(filled, empty);
        Check(!JPTPreviousFields(uri).count, @"empty rewritten fields");
        NSData *old = Response(uri, Value(@"Old", @"Album old", @[@"Artist old"], YES), 178);
        JPTCapturePreviousResponse(old, filled);
        Check(JPTPreviousFields(uri).count == 3, @"all fields");
        JPTCapturePreviousResponse(same, same);
        JPTCapturePreviousResponse(empty, filled);
        Check(JPTPreviousFields(uri).count == 2 && !JPTPreviousFields(uri)[@"title"], @"different official unchanged title invalidates only title");
        JPTCapturePreviousResponse(old, filled);
        gJPTPreviousMetadataRecords = nil;
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"], @"SQLite reload");
        Reset();
        NSData *trackBefore = Response(uri, Value(@"Track old", @"Album", @[@"Artist"], NO), 10);
        NSData *trackAfter = Response(uri, Value(@"New", @"Album", @[@"Artist"], NO), 10);
        JPTCapturePreviousResponse(Join(trackBefore, old), Join(trackAfter, filled));
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"], @"identity priority");
        Reset();
        JPTCapturePreviousResponse(Join(old, empty), Join(filled, filled));
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"], @"duplicate carrier cannot erase old fields");
        Reset();
        NSData *searchBefore = Search(uri, @"Old", @"Old album", @[@"One", @"Two"]);
        NSData *searchAfter = Search(uri, @"New", @"New album", @[@"One new", @"Two"]);
        JPTCapturePreviousSearch(searchBefore, searchAfter);
        Check(JPTPreviousFields(uri).count == 3, @"search all fields");
        Check([JPTPreviousFields(uri)[@"artists"] isEqual:@"One, Two"], @"search artist order");
        JPTCapturePreviousSearch(searchAfter, searchAfter);
        Check(JPTPreviousFields(uri).count == 3, @"search duplicate unchanged keeps record");
        Check(!JPTPreviousFields(two).count && !JPTPreviousFields(@"spotify:album:one").count, @"search URI isolation");
        Reset();
        NSData *prior = searchBefore;
        for (NSUInteger index = 0; index < fields.count; index++) {
            NSData *next = Search(uri, @"New", index >= 1 ? @"New album" : @"Old album", index >= 2 ? @[@"Changed", @"Two"] : @[@"One", @"Two"]);
            JPTCapturePreviousSearch(prior, next);
            prior = next;
        }
        Check(JPTPreviousFields(uri).count == 3, @"separate responses merge changed fields");
        Reset();
        JPTCapturePreviousSearch(Search(uri, nil, @"", @[]), searchAfter);
        Check(!JPTPreviousFields(uri).count, @"search missing old fields");
        Reset();
        NSData *bad = [NSData dataWithBytes:"\x12\xff" length:2];
        JPTCapturePreviousResponse(bad, filled);
        Check(!JPTPreviousFields(uri).count, @"malformed response ignored");
        Reset();
        JPTCapturePreviousResponse(old, filled);
        JPTCapturePreviousResponse(filled, filled);
        Check(JPTPreviousFields(uri).count == 3, @"identical rewritten cache retains history");
        NSData *official = Response(uri, Value(@"Official", @"Official album", @[@"Official artist"], YES), 178);
        JPTCapturePreviousResponse(official, official);
        Check(!JPTPreviousFields(uri).count, @"official unmodified names invalidate all stale fields");
        Check(!gJPTPreviousMetadataRecords[uri], @"empty stale records are removed");
        JPTCapturePreviousResponse(old, filled);
        JPTCapturePreviousResponse(filled, Response(uri, Value(nil, nil, @[], YES), 178));
        Check(!JPTPreviousFields(uri).count, @"observed field removal invalidates record");
        JPTCapturePreviousResponse(old, filled);
        NSData *missing = Response(uri, Value(nil, nil, @[], YES), 178);
        JPTCapturePreviousResponse(missing, missing);
        Check(JPTPreviousFields(uri).count == 3, @"absent values alone are not evidence of stale names");
        JPTCapturePreviousResponse(bad, filled);
        Check(JPTPreviousFields(uri).count == 3, @"bad payload cannot invalidate history");
        JPTCapturePreviousResponse(filled, empty);
        Check(!JPTPreviousFields(uri).count, @"explicit empty title, removed album and incomplete delivered artists invalidate");
        Reset();
        JPTCapturePreviousResponse(old, filled);
        JPTCapturePreviousSearch(searchBefore, searchAfter);
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"] && [JPTPreviousFields(uri)[@"album"] isEqual:@"Album old"], @"lower priority search cannot replace metadata originals");
        NSData *otherSearch = Search(uri, @"Unrelated", @"Unrelated album", @[@"Unrelated artist"]);
        JPTCapturePreviousSearch(otherSearch, otherSearch);
        Check(JPTPreviousFields(uri).count == 3, @"lower priority unchanged source cannot invalidate metadata history");
        JPTCapturePreviousResponse(trackBefore, trackAfter);
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"], @"lower priority track cannot overwrite IdentityTrait");
        Reset();
        JPTCapturePreviousSearch(searchBefore, searchAfter);
        JPTCapturePreviousResponse(old, filled);
        Check([JPTPreviousFields(uri)[@"album"] isEqual:@"Album old"], @"metadata supersedes conflicting search history");
        Reset();
        JPTCapturePreviousSearch(searchBefore, searchAfter);
        NSData *searchNamesAsMetadata = Response(uri, Value(@"New", @"New album", @[@"One new", @"Two"], YES), 178);
        JPTCapturePreviousResponse(searchNamesAsMetadata, searchNamesAsMetadata);
        JPTCapturePreviousSearch(otherSearch, otherSearch);
        Check(JPTPreviousFields(uri).count == 3, @"metadata matching cached new values promotes source authority");
        Reset();
        JPTCapturePreviousResponse(Join(old, trackBefore), Join(filled, trackAfter));
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"], @"mixed response favors IdentityTrait");
        Reset();
        NSData *otherOld = Response(uri, Value(@"Other old", @"Album old", @[@"Artist old"], YES), 178);
        JPTCapturePreviousResponse(Join(old, otherOld), Join(filled, filled));
        Check(!JPTPreviousFields(uri)[@"title"] && JPTPreviousFields(uri).count == 2, @"conflicting duplicate original skips ambiguous title");
        JPTCapturePreviousResponse(old, filled);
        JPTCapturePreviousResponse(Join(old, otherOld), Join(filled, official));
        Check(!JPTPreviousFields(uri).count, @"conflicting duplicate final values invalidate ambiguous fields");
        Reset();
        JPTCapturePreviousResponse(old, filled);
        NSData *differentNew = Response(uri, Value(@"Newest", @"Album", @[@"Artist"], YES), 178);
        JPTCapturePreviousResponse(filled, differentNew);
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"], @"chained rewrite retains initial raw title");
        JPTCapturePreviousResponse(differentNew, differentNew);
        Check([JPTPreviousFields(uri)[@"title"] isEqual:@"Old"], @"chained rewritten cache matches updated delivered value");
        Reset();
        NSData *multiOld = Response(uri, Value(@"Same", @"Same", @[@"One", @"Two"], YES), 178);
        NSData *multiNew = Response(uri, Value(@"Same", @"Same", @[@"One", @"Changed two"], YES), 178);
        JPTCapturePreviousResponse(multiOld, multiNew);
        Check([JPTPreviousFields(uri)[@"artists"] isEqual:@"One, Two"] && JPTPreviousFields(uri).count == 1, @"one renamed artist exposes complete original artist field");
        NSData *reordered = Response(uri, Value(@"Same", @"Same", @[@"Two", @"One"], YES), 178);
        JPTCapturePreviousResponse(multiOld, reordered);
        Check([JPTPreviousFields(uri)[@"artists"] isEqual:@"One, Two"], @"artist order is part of the field");
        Reset();
        NSDictionary *valid = @{@"fields": @{@"title": @{@"old": @"Raw", @"new": @"Localized", @"rank": @3}}};
        JPTStorageOpen();
        JPTStorageExec("INSERT INTO previous_fields VALUES('spotify:track:bad','title','','New',3)");
        gJPTPreviousMetadataRecords = nil;
        Check(!JPTPreviousFields(@"spotify:track:bad").count, @"invalid database row isolated");
        Reset();
        NSMutableArray *many = [NSMutableArray array];
        for (NSUInteger i = 0; i < 2048; i++) [many addObject:@{@"uri": [NSString stringWithFormat:@"spotify:track:%03lu", (unsigned long)i], @"field": @"title", @"pair": valid[@"fields"][@"title"]}];
        Check(JPTStorageCommit(many), @"bulk fixture transaction commits");
        gJPTPreviousMetadataRecords = nil;
        Check([JPTPreviousFields(@"spotify:track:2047")[@"title"] isEqual:@"Raw"] && gJPTPreviousMetadataRecords.count == 2048, @"load retains all records beyond the former cap");
        Check(JPTPreviousFields(@"spotify:track:000").count == 1 && JPTPreviousFields(@"spotify:track:007").count == 1, @"oldest valid records are retained");
        JPTCapturePreviousResponse(old, filled);
        gJPTPreviousMetadataRecords = nil;
        Check(JPTPreviousFields(uri).count == 3 && gJPTPreviousMetadataRecords.count == 2049 && JPTPreviousFields(@"spotify:track:000").count == 1, @"new capture and reload preserve every prior record");
        Reset();
        dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            NSString *concurrentURI = [NSString stringWithFormat:@"spotify:track:concurrent%zu", index];
            JPTCapturePreviousResponse(Response(concurrentURI, Value(@"Raw", @"Album", @[@"Artist"], YES), 178), Response(concurrentURI, Value(@"Localized", @"Album", @[@"Artist"], YES), 178));
        });
        Check(gJPTPreviousMetadataRecords.count == 32, @"parallel captures keep independent records");
        gJPTPreviousMetadataRecords = nil;
        Check(JPTPreviousFields(@"spotify:track:concurrent31").count == 1 && gJPTPreviousMetadataRecords.count == 32, @"parallel capture persistence reload");
        Reset();
        printf("PASS %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
