// Search delivery: unchanged results stay usable, failed lookups retain usable official data.
#define JPT_MANAGEMENT_TEST 1
#include "../JPOriginalTitles.m"
static NSUInteger checks;
static void Check(BOOL value, NSString *label) {
    if (!value) { fprintf(stderr, "FAIL %s\n", label.UTF8String); exit(1); }
    checks++; printf("PASS %s\n", label.UTF8String);
}
static NSData *Search(NSString *track, NSString *name) {
    NSMutableData *entity = [NSMutableData data], *out = [NSMutableData data];
    JPTWriteString(entity, 1, track); JPTWriteString(entity, 2, name);
    JPTWriteData(out, 1, entity);
    return out;
}
static NSString *SearchName(NSData *body) {
    JPTReader r = JPTReaderMake(body.bytes, body.length); JPTField f; BOOL ok;
    while (JPTNext(&r, &f, &ok)) if (f.field == 1 && f.wire == 2) return JPTSubString(&f, 2);
    return nil;
}
static JPTTrackInfo *Track(NSString *name, NSString *canonical) {
    JPTTrackInfo *info = [JPTTrackInfo new];
    info.name = name; info.canonicalURI = canonical; info.artists = [NSMutableArray array];
    return info;
}
static void Finish(NSData *payload, NSData **data, NSError **error) {
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
                                                          delegate:nil delegateQueue:[NSOperationQueue new]];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *got = nil; __block NSError *failure = nil; __block NSUInteger calls = 0;
    JPTFinishSearch(session, gTemplateRequest, payload, ^(NSData *d, NSError *e) {
        got = d; failure = e; calls++; dispatch_semaphore_signal(done);
    });
    Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0, @"search delivery completes");
    [NSThread sleepForTimeInterval:0.2];
    Check(calls == 1, @"search delivery happens exactly once");
    [session finishTasksAndInvalidate];
    *data = got; *error = failure;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *own = @"spotify:track:0000000000000000000001", *original = @"spotify:track:0000000000000000000002";
        gArtistNames = [NSMutableDictionary dictionary]; gArtistChecked = [NSMutableSet set];
        // Port 9 is closed on loopback, so any network lookup fails immediately.
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:9/extended-metadata/v0/extended-metadata"]];
        request.HTTPMethod = @"POST";
        gTemplateRequest = request; gTemplateBody = [NSData data];
        NSData *data = nil; NSError *error = nil;

        NSData *english = Search(own, @"OMGkawaiiAngel");
        gOriginalCache = [@{own: Track(@"OMGkawaiiAngel", nil)} mutableCopy];
        Finish(english, &data, &error);
        Check(!error && [data isEqualToData:english], @"completed lookups without a name change deliver the official payload byte-for-byte");

        NSData *romanized = Search(own, @"Kyuseishu");
        gOriginalCache = [@{own: Track(@"Kyuseishu", original), original: Track(@"救世主", nil)} mutableCopy];
        Finish(romanized, &data, &error);
        Check(!error && [SearchName(data) isEqualToString:@"救世主"], @"a verified original name is still delivered");

        NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"jpt-warning-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        setenv("JPT_TEST_LOG_PATH", logPath.UTF8String, 1); atomic_store(&gJPTLogging, true);
        gOriginalCache = [NSMutableDictionary dictionary];
        Finish(romanized, &data, &error);
        dispatch_sync(JPTLogQueue(), ^{});
        NSString *warning = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
        Check([warning containsString:@"WARNING lookup"] && [warning containsString:own], @"diagnostics identify failed lookup and relevant URI");
        atomic_store(&gJPTLogging, false);
        NSData *logged = [NSData dataWithContentsOfFile:logPath];
        Finish(romanized, &data, &error); dispatch_sync(JPTLogQueue(), ^{});
        Check([logged isEqualToData:[NSData dataWithContentsOfFile:logPath]], @"disabled diagnostics write no warnings");
        [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
        Check(!error && [data isEqualToData:romanized], @"a failed lookup delivers official data without an error");
        Check(!gOriginalCache[own], @"a failed lookup does not create a cache value");

        NSMutableData *partial = [Search(original, @"Official unknown") mutableCopy];
        [partial appendData:Search(own, @"Kyuseishu")];
        NSString *jp = @"spotify:track:0000000000000000000003";
        gOriginalCache = [@{own: Track(@"Kyuseishu", jp), jp: Track(@"救世主", nil)} mutableCopy];
        Finish(partial, &data, &error);
        Check(!error && [JPTSearchTracks(data) isEqualToSet:JPTSearchTracks(partial)], @"partial failure retains every official search entity");
        Check([data rangeOfData:[@"救世主" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,data.length)].location != NSNotFound,
              @"partial failure still applies the verified original name");
        Check(!gOriginalCache[original], @"the failed entity remains retryable");
        const uint8_t invalid[] = {0xff}; NSData *malformed = [NSData dataWithBytes:invalid length:1];
        Finish(malformed, &data, &error);
        Check(!error && [data isEqualToData:malformed], @"unparseable search payload is delivered unchanged");

        gTemplateRequest = nil;
        gOriginalCache = [@{own: Track(@"OMGkawaiiAngel", nil)} mutableCopy];
        Finish(english, &data, &error);
        Check(!error && [data isEqualToData:english], @"search without a lookup template delivers official data");

        gOriginalCache = [@{own: Track(@"Kyuseishu", original), original: Track(@"救世主", nil)} mutableCopy];
        Finish(romanized, &data, &error);
        Check(!error && [SearchName(data) isEqualToString:@"救世主"], @"missing template still applies already verified names");


        atomic_store(&gJPTStrict, true);
        gTemplateRequest=request;
        gOriginalCache=[@{own:Track(@"OMGkawaiiAngel",nil)} mutableCopy];
        Finish(english,&data,&error);
        Check(!error && [data isEqualToData:english],@"strict OMGkawaiiAngel with no rename remains usable");
        gOriginalCache=[@{own:Track(@"",nil)} mutableCopy];
        Finish(english,&data,&error);
        Check(!error && [data isEqualToData:english],@"strict completed empty-name track remains usable");
        gOriginalCache=[NSMutableDictionary dictionary];
        Finish(romanized,&data,&error);
        Check(!data.length && [error.domain isEqualToString:@"JPOriginalTitles.Lookup"],@"strict exhausted search lookup blocks with zero bytes");
        Finish(malformed,&data,&error);
        Check(!data.length && error.code==JPTLookupParseFailure,@"strict malformed search response blocks");
        gTemplateRequest=nil;
        Finish(english,&data,&error);
        Check(!error && [data isEqualToData:english],@"strict search without a template passes through");
        gOriginalCache=[@{own:Track(@"Kyuseishu",original),original:Track(@"救世主",nil)} mutableCopy];
        Finish(romanized,&data,&error);
        Check(!error && [SearchName(data) isEqualToString:@"救世主"],@"strict search without template uses verified cached names");
        NSMutableData *nested=[NSMutableData data], *entity=[NSMutableData data];
        JPTWriteString(entity,1,own);JPTWriteString(entity,2,@"OMGkawaiiAngel");JPTWriteData(entity,5,malformed);JPTWriteData(nested,1,entity);
        Finish(nested,&data,&error);
        Check(!data.length && error.code==JPTLookupParseFailure,@"strict malformed structured search field blocks rather than pretending no rename");
        atomic_store(&gJPTStrict,false);
        Finish(nested,&data,&error);
        Check(!error && [data isEqualToData:nested],@"default malformed structured search field preserves the original payload");
        NSData *empty = [NSData data];
        Finish(empty, &data, &error);
        Check(!error, @"search without tracks completes without an error");
        printf("%lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
