// Search delivery: unchanged results stay usable, failed lookups still reach Spotify as errors.
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

        gOriginalCache = [NSMutableDictionary dictionary];
        Finish(romanized, &data, &error);
        Check(error != nil && data.length == 0, @"a failed lookup still reaches Spotify as an error with no body");
        Check(!gOriginalCache[own], @"a failed lookup does not create a cache value");

        gTemplateRequest = nil;
        gOriginalCache = [@{own: Track(@"OMGkawaiiAngel", nil)} mutableCopy];
        Finish(english, &data, &error);
        Check(error != nil && data.length == 0, @"search without a lookup template still fails");

        NSData *empty = [NSData data];
        Finish(empty, &data, &error);
        Check(!error, @"search without tracks completes without an error");
        printf("%lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
